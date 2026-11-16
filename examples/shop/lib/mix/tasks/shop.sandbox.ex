defmodule Mix.Tasks.Shop.Sandbox do
  @shortdoc "Fills the Stripe sandbox and the shop with test payments in every status"

  @moduledoc """
  Makes test payments on the Stripe sandbox, for many buyers and products, in every status the
  shop shows: paid, part refunded, refunded, failed (declined, insufficient funds), waiting for
  3D Secure, waiting for a card, and canceled. Each one is then synced into the shop's payments
  table through Mishka Pay (`:sync`), and refunds go through Mishka Pay's `:refund` action.

      mix shop.sandbox

  It only runs with a test key (`sk_test_...` in `.env`): Stripe's test cards move no money. A
  payment is made directly as a PaymentIntent with a test card, the way Stripe's own tests do,
  so no browser is needed.
  """

  use Mix.Task

  alias MishkaPay.Client
  alias MishkaPay.Providers.Stripe
  alias Shop.Pay.Payment

  @tenant "demo"

  # {product id, quantity, buyer, test card or nil, what happens after}
  @scenarios [
    {"ebook", 1, "Ava Martin", "pm_card_mastercard", :keep},
    {"course", 1, "Noah Brown", "pm_card_amex", :keep},
    {"stickers", 3, "Mia Johnson", "pm_card_discover", :keep},
    {"workshop", 1, "Leo Garcia", "pm_card_visa_debit", :keep},
    {"ashbook", 2, "Emma Wilson", "pm_card_mastercard", :keep},
    {"hoodie", 1, "Lucas Taylor", "pm_card_amex", :keep},
    {"course", 1, "Olivia Davis", "pm_card_mastercard",
     {:refund, "10.00", :requested_by_customer}},
    {"ebook", 2, "Ethan Moore", "pm_card_discover", {:refund, "5.00", nil}},
    {"hoodie", 1, "Sophia Clark", "pm_card_visa_debit",
     {:refund, "12.50", :requested_by_customer}},
    {"workshop", 1, "James Lewis", "pm_card_mastercard", {:refund, nil, :requested_by_customer}},
    {"stickers", 2, "Isabella Hall", "pm_card_amex", {:refund, nil, :duplicate}},
    {"ashbook", 1, "Henry Young", "pm_card_discover", {:refund, nil, nil}},
    {"ebook", 1, "Charlotte King", "pm_card_chargeDeclined", :keep},
    {"course", 1, "Benjamin Scott", "pm_card_chargeDeclinedInsufficientFunds", :keep},
    {"workshop", 1, "Amelia Green", "pm_card_authenticationRequired", :keep},
    {"hoodie", 1, "Jack Adams", nil, :keep},
    {"stickers", 1, "Harper Baker", nil, :cancel}
  ]

  @impl Mix.Task
  def run(_args) do
    # Its own plugin registry, so it can run while `mix phx.server` holds the shop's one.
    Application.put_env(:mishka_installer, MishkaInstaller.MnesiaRepo,
      mnesia_dir:
        Path.join(System.tmp_dir!(), "shop-sandbox-#{System.unique_integer([:positive])}"),
      essential: [MishkaInstaller.Event.Event, MishkaInstaller.Installer.Installer]
    )

    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    key = System.get_env("STRIPE_SECRET_KEY") || ""

    unless String.starts_with?(key, "sk_test_"),
      do: Mix.raise("shop.sandbox runs only with a Stripe test key (sk_test_...) in .env")

    Mix.shell().info("Making #{length(@scenarios)} sandbox payments...\n")

    for {product_id, quantity, buyer, card, after_payment} <- @scenarios do
      product = Shop.Catalog.fetch(product_id)
      customer = customer(key, buyer)
      intent_id = pay(key, product, quantity, customer, card)
      :ok = follow_up(key, intent_id, after_payment)

      case sync(intent_id) |> refund(after_payment) do
        {:ok, payment} ->
          Mix.shell().info(
            "  #{String.pad_trailing(buyer, 16)} #{String.pad_trailing(product.name, 20)} " <>
              "#{payment.status} (#{intent_id})"
          )

        {:error, error} ->
          Mix.shell().error("  #{buyer}: #{MishkaPay.Ash.message(error)}")
      end
    end

    Mix.shell().info("\nDone. Open the shop to see them: http://localhost:4041")
  end

  defp customer(key, name) do
    email = name |> String.downcase() |> String.replace(" ", ".") |> Kernel.<>("@example.com")
    {200, %{"id" => id}} = stripe(key, "/v1/customers", %{"name" => name, "email" => email})
    id
  end

  # A card pays at once; a declined card leaves a failed PaymentIntent; no card leaves one
  # waiting for a payment method.
  defp pay(key, product, quantity, customer, card) do
    cents = product.price |> Decimal.new() |> Decimal.mult(quantity) |> Decimal.mult(100)

    params =
      %{
        "amount" => Decimal.to_integer(cents),
        "currency" => "usd",
        "customer" => customer,
        "description" => "#{quantity} × #{product.name}",
        "metadata" => %{"mishka_pay_reference" => Shop.Catalog.reference(product)},
        "automatic_payment_methods" => %{"enabled" => "true", "allow_redirects" => "never"}
      }
      |> Map.merge(card_params(card))

    case stripe(key, "/v1/payment_intents", params) do
      {200, %{"id" => id}} -> id
      {402, %{"error" => %{"payment_intent" => %{"id" => id}}}} -> id
    end
  end

  defp card_params(nil), do: %{}
  defp card_params(card), do: %{"payment_method" => card, "confirm" => "true"}

  defp follow_up(key, intent_id, :cancel) do
    {200, _canceled} = stripe(key, "/v1/payment_intents/#{intent_id}/cancel", %{})
    :ok
  end

  defp follow_up(_key, _intent_id, _keep_or_refund), do: :ok

  defp sync(intent_id) do
    Ash.create(Payment, %{provider: "stripe", payment_id: intent_id, tenant: @tenant},
      action: :sync,
      authorize?: false
    )
  end

  defp refund({:ok, payment}, {:refund, amount, reason}) do
    payment
    |> Ash.Changeset.for_update(:refund, refund_args(amount, reason))
    |> Ash.update(authorize?: false)
  end

  defp refund(synced, _keep), do: synced

  defp refund_args(nil, reason),
    do: %{reason: reason, reference: "seed-refund-" <> Ecto.UUID.generate()}

  defp refund_args(amount, reason),
    do: Map.put(refund_args(nil, reason), :amount, %{amount: amount, currency: "USD"})

  defp stripe(key, path, params) do
    {:ok, %{status: status, body: body}} =
      Client.request(%{
        provider: "stripe",
        method: :post,
        base_url: "https://api.stripe.com",
        path: path,
        auth: {:bearer, key},
        headers: %{"stripe-version" => Stripe.version()},
        form: Stripe.form(params)
      })

    {status, body}
  end
end

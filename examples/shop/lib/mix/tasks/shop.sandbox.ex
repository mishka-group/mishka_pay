defmodule Mix.Tasks.Shop.Sandbox do
  @shortdoc "Fills the Stripe and PayPal sandboxes and the shop with test payments"

  @moduledoc """
  Makes test payments on the Stripe sandbox, for many buyers and products, in every status the
  shop shows: paid, part refunded, refunded, failed (declined, insufficient funds), waiting for
  3D Secure, waiting for a card, and canceled. Then subscriptions to the seeded plans: active, in
  trial, ending at the period's end, and canceled. Each one is then synced into the shop's payments
  table through Mishka Pay (`:sync`), and refunds go through Mishka Pay's `:refund` action.

      mix shop.sandbox                 # makes the payments, the subscriptions, and PayPal's
      mix shop.sandbox subscriptions   # makes only the subscriptions
      mix shop.sandbox paypal          # makes only the PayPal ones
      mix shop.sandbox resync          # reads every stored payment from its provider again

  It only runs with a test key (`sk_test_...` in `.env`): Stripe's test cards move no money. A
  payment is made directly as a PaymentIntent with a test card, the way Stripe's own tests do,
  so no browser is needed.

  With PayPal sandbox keys in `.env` (`PAYPAL_CLIENT_ID`, `PAYPAL_CLIENT_SECRET`) it also makes
  PayPal Orders and a PayPal subscription. A PayPal buyer approves on PayPal's page, so these wait
  for the buyer: their approval links are printed, to pay them with a sandbox personal account.
  """

  use Mix.Task

  alias Shop.Pay.{Payment, StripeSandbox}

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

  # {plan slug, buyer, what happens after}
  @subscriptions [
    {"pro-monthly", "Grace Hopper", :keep},
    {"team-monthly", "Alan Turing", :keep},
    {"pro-yearly", "Ada Lovelace", :cancel_at_period_end},
    {"pro-monthly", "Linus Torvalds", :cancel_now}
  ]

  # {product id, quantity} paid with PayPal, and the plan subscribed with PayPal.
  @paypal_orders [{"ebook", 1}, {"course", 1}, {"stickers", 2}]
  @paypal_plan "pro-monthly"

  @impl Mix.Task
  def run(args) do
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

    case args do
      ["resync"] -> resync()
      ["subscriptions"] -> make_subscriptions(key)
      ["paypal"] -> make_paypal()
      _make -> make(key)
    end
  end

  defp resync do
    payments = Ash.read!(Payment, authorize?: false)
    Mix.shell().info("Reading #{length(payments)} payments from their providers again...")

    for payment <- payments do
      case sync(payment.provider_id, payment.provider) do
        {:ok, synced} ->
          Mix.shell().info("  #{synced.provider_id} #{synced.status}")

        {:error, error} ->
          Mix.shell().error("  #{payment.provider_id}: #{MishkaPay.Ash.message(error)}")
      end
    end
  end

  defp make(key) do
    Mix.shell().info("Making #{length(@scenarios)} sandbox payments...\n")

    for {product_id, quantity, buyer, card, after_payment} <- @scenarios do
      product =
        Shop.Catalog.fetch(product_id) ||
          Mix.raise("No product #{product_id}: run `mix run priv/repo/seeds.exs` first")

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

    make_subscriptions(key)

    case paypal?() do
      true -> make_paypal()
      false -> Mix.shell().info("\nNo PayPal sandbox keys in .env: no PayPal rows.")
    end

    Mix.shell().info("\nDone. Open the shop to see them: http://localhost:4041")
  end

  defp paypal?, do: match?({:ok, _keys}, MishkaPay.Credentials.fetch("paypal", @tenant))

  defp make_paypal do
    unless paypal?(), do: Mix.raise("PayPal rows need PAYPAL_CLIENT_ID and PAYPAL_CLIENT_SECRET")
    Mix.shell().info("\nMaking PayPal Orders and a subscription, waiting for the buyer...\n")

    for {product_id, quantity} <- @paypal_orders do
      product = Shop.Catalog.fetch(product_id) || Mix.raise("No product #{product_id}")

      with {:ok, checkout} <- paypal_checkout(product, quantity, :payment),
           {:ok, payment} <- sync(checkout.id, "paypal") do
        Mix.shell().info(
          "  #{String.pad_trailing(product.name, 24)} #{payment.status} #{checkout.url}"
        )
      else
        {:error, error} -> Mix.shell().error("  #{product.name}: #{MishkaPay.Ash.message(error)}")
      end
    end

    plan = Shop.Catalog.fetch(@paypal_plan) || Mix.raise("No plan #{@paypal_plan}")

    with {:ok, checkout} <- paypal_checkout(plan, 1, :subscription),
         {:ok, sub} <- sync_subscription(checkout.id, "paypal") do
      Mix.shell().info("  #{String.pad_trailing(plan.name, 24)} #{sub.status} #{checkout.url}")
    else
      {:error, error} -> Mix.shell().error("  #{plan.name}: #{MishkaPay.Ash.message(error)}")
    end
  end

  defp paypal_checkout(product, quantity, mode) do
    MishkaPay.checkout(%{
      provider: "paypal",
      tenant: @tenant,
      mode: mode,
      trial_days: product.trial_days,
      items: [
        %{
          name: product.name,
          amount: %{amount: product.price, currency: "USD"},
          quantity: quantity,
          interval: product.interval,
          interval_count: product.interval && product.interval_count
        }
      ],
      success_url: "http://localhost:4041/?provider=paypal",
      cancel_url: "http://localhost:4041/?canceled=1",
      reference: Shop.Catalog.reference(product)
    })
  end

  defp make_subscriptions(_key) do
    Mix.shell().info("\nMaking #{length(@subscriptions)} sandbox subscriptions...\n")

    for {plan_slug, buyer, after_start} <- @subscriptions do
      plan =
        Shop.Catalog.fetch(plan_slug) || Mix.raise("No plan #{plan_slug}: run the seeds first")

      case plan
           |> StripeSandbox.subscribe(customer_with_card(buyer))
           |> sync_subscription()
           |> then_do(after_start) do
        {:ok, sub} ->
          Mix.shell().info(
            "  #{String.pad_trailing(buyer, 16)} #{String.pad_trailing(plan.name, 24)} " <>
              "#{sub.status}#{if sub.cancel_at_period_end, do: ", ends at period end"} (#{sub.provider_id})"
          )

        {:error, error} ->
          Mix.shell().error("  #{buyer}: #{MishkaPay.Ash.message(error)}")
      end
    end
  end

  # A buyer with a Mastercard test card on file, as a subscription renews with it.
  defp customer_with_card(name) do
    customer = StripeSandbox.customer(name)
    StripeSandbox.default_card(customer, "pm_card_mastercard")
    customer
  end

  defp sync_subscription(subscription_id, provider \\ "stripe") do
    Ash.create(
      Shop.Pay.Subscription,
      %{provider: provider, subscription_id: subscription_id, tenant: @tenant},
      action: :sync,
      authorize?: false
    )
  end

  defp then_do({:ok, sub}, :cancel_at_period_end), do: cancel(sub, :period_end)
  defp then_do({:ok, sub}, :cancel_now), do: cancel(sub, :now)
  defp then_do(synced, :keep), do: synced

  defp cancel(sub, at) do
    sub
    |> Ash.Changeset.for_update(:cancel, %{at: at})
    |> Ash.update(authorize?: false)
  end

  defp customer(_key, name), do: StripeSandbox.customer(name)

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

  defp sync(payment_id, provider \\ "stripe") do
    Ash.create(Payment, %{provider: provider, payment_id: payment_id, tenant: @tenant},
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

  defp stripe(_key, path, params), do: StripeSandbox.post(path, params)
end

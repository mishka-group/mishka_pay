defmodule Shop.Pay.StripeSandbox do
  @moduledoc """
  Test set-up the demo makes straight on the Stripe sandbox, where a real buyer would act in a
  browser: customers with one of Stripe's test cards on file, and subscriptions made for them.
  `mix shop.sandbox` and the test clocks panel both use it. Only with a test key.
  """

  alias MishkaPay.Client
  alias MishkaPay.Providers.Stripe

  @doc "The sandbox key from the environment, refused unless it is a test key."
  def key! do
    key = System.get_env("STRIPE_SECRET_KEY") || ""

    case String.starts_with?(key, "sk_test_") do
      true ->
        key

      false ->
        raise ArgumentError, "the Stripe sandbox set-up runs only with a test key (sk_test_...)"
    end
  end

  @doc "A customer named `name`, on test clock `opts[:clock]` when given."
  def customer(name, opts \\ []) do
    email = name |> String.downcase() |> String.replace(" ", ".") |> Kernel.<>("@example.com")

    {200, %{"id" => id}} =
      post("/v1/customers", %{"name" => name, "email" => email, "test_clock" => opts[:clock]})

    id
  end

  @doc """
  Puts Stripe's test card `card` (such as `"pm_card_mastercard"`, or `"pm_card_chargeCustomerFail"`
  whose charges fail) on `customer` as the card future invoices are paid with.
  """
  def default_card(customer, card) do
    {200, %{"id" => method}} =
      post("/v1/payment_methods/#{card}/attach", %{"customer" => customer})

    {200, _customer} =
      post("/v1/customers/#{customer}", %{
        "invoice_settings" => %{"default_payment_method" => method}
      })

    method
  end

  @doc "A subscription for `customer` to `plan` (a seeded plan), with the plan's trial."
  def subscribe(plan, customer) do
    {200, %{"id" => product}} = post("/v1/products", %{"name" => plan.name})
    cents = plan.price |> Decimal.mult(100) |> Decimal.to_integer()

    {200, %{"id" => id}} =
      post("/v1/subscriptions", %{
        "customer" => customer,
        "trial_period_days" => plan.trial_days,
        "metadata" => %{"mishka_pay_reference" => Shop.Catalog.reference(plan)},
        "items" => [
          %{
            "price_data" => %{
              "currency" => "usd",
              "product" => product,
              "unit_amount" => cents,
              "recurring" => %{
                "interval" => Atom.to_string(plan.interval),
                "interval_count" => plan.interval_count
              }
            }
          }
        ]
      })

    id
  end

  @doc "A POST to the Stripe sandbox, answered as `{status, body}`."
  def post(path, params) do
    {:ok, %{status: status, body: body}} =
      Client.request(%{
        provider: "stripe",
        method: :post,
        base_url: "https://api.stripe.com",
        path: path,
        auth: {:bearer, key!()},
        headers: %{"stripe-version" => Stripe.version()},
        form: Stripe.form(params)
      })

    {status, body}
  end
end

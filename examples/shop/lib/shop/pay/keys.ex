defmodule Shop.Pay.Keys do
  @moduledoc """
  Answers Mishka Pay's `mishka_pay:credentials` event: the Stripe and PayPal sandbox keys from the
  environment, and the site's own settings (`Shop.Pay.Setting`) from the database, read again on
  every call.

  PayPal needs `PAYPAL_CLIENT_ID` and `PAYPAL_CLIENT_SECRET` (a sandbox app's), and for its
  webhooks `PAYPAL_WEBHOOK_ID`. The merchant-of-record setting is Stripe's, so PayPal gets only the
  refund rule.

  The webhook secret is `STRIPE_WEBHOOK_SECRET` (the one `stripe listen` prints), or a local one the
  page's webhook simulator signs with when it is not set.
  """

  @local_webhook_secret "whsec_demo_local_only"

  @doc "The webhook secret Stripe's messages, or the simulator's, are checked with."
  def webhook_secret, do: System.get_env("STRIPE_WEBHOOK_SECRET") || @local_webhook_secret

  @doc "Whether the secret is the simulator's own, so real Stripe webhooks would not verify."
  def local_webhook_secret?, do: webhook_secret() == @local_webhook_secret

  use MishkaPay.Credentials

  require Ash.Query

  @impl MishkaPay.Credentials
  # Only the demo site has keys: any other tenant is a site this shop does not know.
  def credentials(_provider, tenant) when tenant != "demo", do: nil

  def credentials("stripe", tenant) do
    with key when is_binary(key) <- System.get_env("STRIPE_SECRET_KEY") do
      %{secret_key: key, webhook_secret: webhook_secret()}
      |> Map.merge(settings(tenant))
      |> Map.reject(fn {_name, value} -> is_nil(value) end)
    end
  end

  def credentials("paypal", tenant) do
    with id when is_binary(id) <- System.get_env("PAYPAL_CLIENT_ID"),
         secret when is_binary(secret) <- System.get_env("PAYPAL_CLIENT_SECRET") do
      %{
        publishable_key: id,
        secret_key: secret,
        webhook_secret: System.get_env("PAYPAL_WEBHOOK_ID"),
        mode: :test
      }
      |> Map.merge(Map.take(settings(tenant), [:refunds]))
      |> Map.reject(fn {_name, value} -> is_nil(value) end)
    end
  end

  def credentials(_provider, _tenant), do: nil

  defp settings(tenant) do
    Shop.Pay.Setting
    |> Ash.Query.filter(tenant == ^tenant)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{refunds: refunds, merchant_of_record: merchant_of_record, automatic_tax: tax}} ->
        %{refunds: refunds, merchant_of_record: merchant_of_record, automatic_tax: tax}

      _none ->
        %{}
    end
  end
end

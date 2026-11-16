defmodule Shop.Pay.Keys do
  @moduledoc """
  Answers Mishka Pay's `mishka_pay:credentials` event: the Stripe sandbox keys from the
  environment, and the site's own settings (`Shop.Pay.Setting`) from the database, read again on
  every call.

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
  def credentials("stripe", tenant) do
    with key when is_binary(key) <- System.get_env("STRIPE_SECRET_KEY") do
      %{secret_key: key, webhook_secret: webhook_secret()}
      |> Map.merge(settings(tenant))
      |> Map.reject(fn {_name, value} -> is_nil(value) end)
    end
  end

  def credentials(_provider, _tenant), do: nil

  defp settings(tenant) do
    Shop.Pay.Setting
    |> Ash.Query.filter(tenant == ^tenant)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{refunds: refunds, merchant_of_record: merchant_of_record}} ->
        %{refunds: refunds, merchant_of_record: merchant_of_record}

      _none ->
        %{}
    end
  end
end

defmodule Shop.Pay.WebhookSimulator do
  @moduledoc """
  Sends the shop a Stripe webhook about one payment, signed the way Stripe signs, to its own
  `MishkaPay.Webhook` endpoint over HTTP. The event then goes the whole way a real one goes:
  signature check, the inbox, an Oban job, the payment sync and `mishka_pay:payment:changed`.
  With `:bad_signature` it signs with the wrong secret, to show the endpoint refuse it.
  """

  alias MishkaPay.Providers.Stripe

  @types [
    "payment_intent.succeeded",
    "payment_intent.payment_failed",
    "payment_intent.canceled",
    "charge.refunded"
  ]

  @doc "The event types the simulator sends."
  def types, do: @types

  @doc "Sends `type` about `payment_id` for `tenant`; answers the HTTP status and the event id."
  def send_event(payment_id, type, tenant, signature \\ :good) when type in @types do
    event_id = "evt_sim_" <> String.replace(Ecto.UUID.generate(), "-", "")
    time = System.system_time(:second)

    body =
      JSON.encode!(%{
        "id" => event_id,
        "object" => "event",
        "type" => type,
        "created" => time,
        "livemode" => false,
        "api_version" => Stripe.version(),
        "data" => %{"object" => object(type, payment_id)}
      })

    secret =
      case signature do
        :good -> Shop.Pay.Keys.webhook_secret()
        :bad_signature -> "whsec_not_the_right_one"
      end

    {:ok, %{status: status}} =
      Req.post(ShopWeb.Endpoint.url() <> "/pay/webhooks/stripe/#{tenant}",
        body: body,
        headers: [
          {"content-type", "application/json"},
          {"stripe-signature", "t=#{time},v1=#{Stripe.signature(body, time, secret)}"}
        ],
        retry: false
      )

    {status, event_id}
  end

  defp object("charge.refunded", payment_id),
    do: %{"id" => "ch_sim", "object" => "charge", "payment_intent" => payment_id}

  defp object(_intent_event, payment_id), do: %{"id" => payment_id, "object" => "payment_intent"}
end

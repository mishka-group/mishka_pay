defmodule Shop.Pay.WebhookSimulator do
  @moduledoc """
  Sends the shop a Stripe webhook about one payment (`pi_...`) or subscription (`sub_...`), signed the way Stripe signs, to its own
  `MishkaPay.Webhook` endpoint over HTTP. The event then goes the whole way a real one goes:
  signature check, the inbox, an Oban job, the payment sync and `mishka_pay:payment:changed`.
  With `:bad_signature` it signs with the wrong secret, to show the endpoint refuse it; with
  `:rolled_secret`, with the secret from before a roll, which the endpoint still takes.

  A `v1.` type is sent as a thin event notification, as a Stripe event destination with the thin
  payload sends it (the shape of `MishkaPay.Test.signed_thin_event/4`): it names its object only. The thin
  types here are about a PaymentIntent or a subscription, which name the id the event needs, so
  the webhook reads nothing from Stripe for them (a thin `v1.charge.refunded` or
  `v1.invoice.paid` would be read from Stripe, which knows no simulated object).
  """

  alias MishkaPay.Providers.Stripe

  @snapshot_types [
    "payment_intent.succeeded",
    "payment_intent.payment_failed",
    "payment_intent.canceled",
    "charge.refunded",
    "customer.subscription.updated",
    "customer.subscription.deleted",
    "invoice.paid",
    "invoice.payment_failed"
  ]

  @thin_types [
    "v1.payment_intent.succeeded",
    "v1.payment_intent.payment_failed",
    "v1.customer.subscription.updated",
    "v1.customer.subscription.active",
    "v1.customer.subscription.past_due"
  ]

  @types @snapshot_types ++ @thin_types

  @doc "The event types the simulator sends: snapshot ones, then thin ones (`v1.`)."
  def types, do: @types

  @situations [
    good: %{label: "Good signature", expect: [200]},
    rolled_secret: %{label: "Signed with the secret before a roll", expect: [200]},
    bad_signature: %{label: "Bad signature", expect: [400]},
    old_timestamp: %{label: "Too old (a replay, over 5 minutes)", expect: [400]},
    unknown_tenant: %{label: "A site with no keys", expect: [400]},
    unknown_provider: %{label: "A provider not installed", expect: [404]},
    wrong_method: %{label: "GET instead of POST", expect: [405]},
    too_large: %{label: "A body over 1 MB", expect: [413]},
    listener_fails: %{label: "A listener fails to take it", expect: [500]},
    twice: %{label: "The same event twice", expect: [200, 200]}
  ]

  @doc """
  Every situation the simulator plays, with what the endpoint must answer; a rolled secret only
  when the site still accepts one (`Shop.Pay.Keys.old_webhook_secrets/0`).
  """
  def situations do
    case Shop.Pay.Keys.old_webhook_secrets() do
      [] -> Keyword.delete(@situations, :rolled_secret)
      _old -> @situations
    end
  end

  @doc """
  Sends a `type` event about `id` for `tenant` in `situation`, and answers the HTTP statuses the
  endpoint gave (two for `:twice`) and the event id.
  """
  def send_event(id, type, tenant, situation) when type in @types do
    event_id = "evt_sim_" <> String.replace(Ecto.UUID.generate(), "-", "")

    time =
      if situation == :old_timestamp,
        do: System.system_time(:second) - 600,
        else: System.system_time(:second)

    event_type = if situation == :listener_fails, do: Shop.Pay.FailingListener.type(), else: type

    body =
      type
      |> event(event_type, id, time)
      |> Map.merge(%{"id" => event_id, "livemode" => false, "padding" => padding(situation)})
      |> JSON.encode!()

    secret = secret(situation)

    request =
      request(situation, tenant, body, "t=#{time},v1=#{Stripe.signature(body, time, secret)}")

    times = if situation == :twice, do: 2, else: 1

    {Enum.map(1..times, fn _try -> deliver(request) end), event_id}
  end

  # A thin notification names its object, with Stripe's time in RFC 3339; a snapshot event
  # carries it, with the pinned API version.
  defp event("v1." <> snapshot_type, event_type, id, time) do
    object = object(snapshot_type, id)

    %{
      "object" => "v2.core.event",
      "type" => event_type,
      "created" => time |> DateTime.from_unix!() |> DateTime.to_iso8601(),
      "context" => nil,
      "related_object" => %{
        "id" => object["id"],
        "type" => object["object"],
        "url" => url(object)
      }
    }
  end

  defp event(type, event_type, id, time) do
    %{
      "object" => "event",
      "type" => event_type,
      "created" => time,
      "api_version" => Stripe.version(),
      "data" => %{"object" => object(type, id)}
    }
  end

  defp url(%{"object" => "subscription", "id" => id}), do: "/v1/subscriptions/#{id}"
  defp url(%{"object" => "payment_intent", "id" => id}), do: "/v1/payment_intents/#{id}"

  defp secret(:bad_signature), do: "whsec_not_the_right_one"
  defp secret(:rolled_secret), do: List.first(Shop.Pay.Keys.old_webhook_secrets())
  defp secret(_signed_now), do: Shop.Pay.Keys.webhook_secret()

  defp request(situation, tenant, body, signature) do
    provider = if situation == :unknown_provider, do: "nopay", else: "stripe"
    tenant = if situation == :unknown_tenant, do: "site-without-keys", else: tenant

    %{
      method: if(situation == :wrong_method, do: :get, else: :post),
      url: ShopWeb.Endpoint.url() <> "/pay/webhooks/#{provider}/#{tenant}",
      body: body,
      signature: signature
    }
  end

  defp deliver(%{method: method, url: url, body: body, signature: signature}) do
    {:ok, %{status: status}} =
      Req.request(
        method: method,
        url: url,
        body: if(method == :get, do: nil, else: body),
        headers: [{"content-type", "application/json"}, {"stripe-signature", signature}],
        retry: false
      )

    status
  end

  # Over the endpoint's 1 MB limit.
  defp padding(:too_large), do: String.duplicate("x", 1_100_000)
  defp padding(_fits), do: nil

  defp object("customer.subscription." <> _change, subscription_id),
    do: %{"id" => subscription_id, "object" => "subscription"}

  defp object("invoice." <> _change, subscription_id),
    do: %{
      "id" => "in_sim",
      "object" => "invoice",
      "parent" => %{"subscription_details" => %{"subscription" => subscription_id}}
    }

  defp object("charge.refunded", payment_id),
    do: %{"id" => "ch_sim", "object" => "charge", "payment_intent" => payment_id}

  defp object(_intent_event, payment_id), do: %{"id" => payment_id, "object" => "payment_intent"}
end

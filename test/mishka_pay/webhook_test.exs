# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.WebhookTest do
  # Starts the Stripe and listener plugins, which change events every test sees.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias MishkaPay.{Event, Webhook}
  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Support.EventListener

  # Stripe's own event fixture, recorded from stripe-mock.
  @event "test/fixtures/stripe/event.json" |> File.read!() |> JSON.decode!()
  @secret "whsec_test_site_a"
  @opts Webhook.init(at: "/pay/webhooks")

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.start_plugin!(EventListener)

    MishkaPay.Test.put_keys(
      "stripe",
      %{secret_key: "sk_test_a", webhook_secret: @secret},
      "site-a"
    )

    ref = :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :webhook, :stop]])
    %{ref: ref}
  end

  defp payload(changes \\ %{}), do: @event |> Map.merge(changes) |> JSON.encode!()

  defp signed(body, opts \\ []) do
    time = Keyword.get(opts, :time, System.system_time(:second))
    secret = Keyword.get(opts, :secret, @secret)
    "t=#{time},v1=#{Stripe.signature(body, time, secret)}"
  end

  defp post(path, body, signature) do
    conn(:post, path, body)
    |> put_req_header("content-type", "application/json")
    |> then(&if(signature, do: put_req_header(&1, "stripe-signature", signature), else: &1))
    |> Webhook.call(@opts)
  end

  test "a signed Stripe event reaches the listeners with its tenant, and Stripe gets 200", %{
    ref: ref
  } do
    body = payload(%{"type" => "payment_intent.succeeded"})
    conn = post("/pay/webhooks/stripe/site-a", body, signed(body))

    assert conn.status == 200
    assert conn.halted

    assert_received {:webhook_event,
                     %Event{
                       provider: "stripe",
                       tenant: "site-a",
                       id: "evt_123",
                       type: "payment_intent.succeeded"
                     } = event}

    assert event.object_id == @event["data"]["object"]["id"]
    assert event.livemode == false

    assert_received {[:mishka_pay, :webhook, :stop], ^ref, _,
                     %{
                       status: 200,
                       outcome: :ok,
                       type: "payment_intent.succeeded",
                       tenant: "site-a"
                     }}
  end

  test "a message Stripe did not sign, or signed for someone else, never reaches a listener", %{
    ref: ref
  } do
    body = payload()
    old = System.system_time(:second) - 3_600

    for {signature, reason} <- [
          {nil, :missing},
          {"v1=abc", :malformed},
          {signed(body, secret: "whsec_other"), :mismatch},
          {signed(body, time: old), :too_old}
        ] do
      assert post("/pay/webhooks/stripe/site-a", body, signature).status == 400
      assert_received {[:mishka_pay, :webhook, :stop], ^ref, _, %{status: 400, outcome: ^reason}}
    end

    tampered = String.replace(body, "evt_123", "evt_999")
    assert post("/pay/webhooks/stripe/site-a", tampered, signed(body)).status == 400
    refute_received {:webhook_event, _event}
  end

  test "a live event checked with test keys is refused", %{ref: ref} do
    body = payload(%{"livemode" => true})

    assert post("/pay/webhooks/stripe/site-a", body, signed(body)).status == 400
    assert_received {[:mishka_pay, :webhook, :stop], ^ref, _, %{outcome: :mode}}
  end

  test "a rolled secret still works while Stripe signs with both" do
    body = payload()
    time = System.system_time(:second)

    both =
      "t=#{time},v1=#{Stripe.signature(body, time, "whsec_old")},v1=#{Stripe.signature(body, time, @secret)}"

    assert post("/pay/webhooks/stripe/site-a", body, both).status == 200
  end

  test "a listener that cannot take the event makes Stripe send it again", %{ref: ref} do
    body = payload(%{"type" => "listener.fails"})

    assert post("/pay/webhooks/stripe/site-a", body, signed(body)).status == 500
    assert_received {[:mishka_pay, :webhook, :stop], ^ref, _, %{status: 500, outcome: :failed}}
  end

  test "an unknown provider is 404, an unknown tenant 400 like a bad signature, and other methods and paths are not ours" do
    body = payload()

    assert post("/pay/webhooks/acme/site-a", body, signed(body)).status == 404
    assert post("/pay/webhooks/stripe/site-without-keys", body, signed(body)).status == 400

    assert (conn(:get, "/pay/webhooks/stripe/site-a") |> Webhook.call(@opts)).status == 405

    elsewhere = conn(:post, "/checkout", "{}") |> Webhook.call(@opts)
    refute elsewhere.halted
    assert elsewhere.status == nil
  end

  test "a signed event with an odd shape or time is refused or read, never a crash" do
    for changes <- [%{"data" => "x"}, %{"data" => %{"object" => [1]}}, %{"data" => []}] do
      body = payload(changes)
      assert post("/pay/webhooks/stripe/site-a", body, signed(body)).status == 200
      assert_received {:webhook_event, %Event{object_id: nil}}
    end

    body = payload(%{"created" => 99_999_999_999_999_999_999})
    assert post("/pay/webhooks/stripe/site-a", body, signed(body)).status == 200
    assert_received {:webhook_event, %Event{created_at: nil}}
  end

  test "a tenant from the path reaches telemetry only once the signature proves it", %{ref: ref} do
    body = payload()
    assert post("/pay/webhooks/stripe/made-up-tenant", body, signed(body)).status == 400
    assert_received {[:mishka_pay, :webhook, :stop], ^ref, _, meta}
    refute Map.has_key?(meta, :tenant)
  end

  test "the plug must be given a path of its own" do
    for opts <- [[], [at: "/"], [at: ""]] do
      assert_raise ArgumentError, ~r/path of its own/, fn -> Webhook.init(opts) end
    end
  end

  test "a body too large to be a webhook is refused before anything reads it" do
    body = String.duplicate("a", 1_000_001)
    assert post("/pay/webhooks/stripe/site-a", body, signed(body)).status == 413
  end

  test "mounted after the parsers, the raw body kept by read_body/3 is the one checked" do
    body = payload()

    conn =
      conn(:post, "/pay/webhooks/stripe/site-a", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signed(body))
      |> Plug.Parsers.call(
        Plug.Parsers.init(
          parsers: [:json],
          json_decoder: JSON,
          body_reader: {Webhook, :read_body, ["/pay/webhooks"]}
        )
      )

    assert conn.body_params["id"] == "evt_123"
    assert Webhook.call(conn, @opts).status == 200
    assert_received {:webhook_event, %Event{id: "evt_123"}}
  end
end

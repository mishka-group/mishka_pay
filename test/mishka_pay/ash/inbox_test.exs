# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Ash.InboxTest do
  # Starts plugins and shares the sandboxed database with their tasks.
  use MishkaPay.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias MishkaPay.{Event, Webhook}
  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Support.{EventWorker, WebhookEvent}
  alias MishkaPay.Support.WebhookEvent.MishkaPayListener, as: Inbox

  @event "test/fixtures/stripe/event.json" |> File.read!() |> JSON.decode!()
  @secret "whsec_test_site_a"
  @opts Webhook.init(at: "/pay/webhooks")

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.start_plugin!(Inbox)

    MishkaPay.Test.put_keys(
      "stripe",
      %{secret_key: "sk_test_a", webhook_secret: @secret},
      "site-a"
    )

    :ok
  end

  defp deliver(changes) do
    body = @event |> Map.merge(changes) |> JSON.encode!()
    time = System.system_time(:second)

    conn(:post, "/pay/webhooks/stripe/site-a", body)
    |> put_req_header("stripe-signature", "t=#{time},v1=#{Stripe.signature(body, time, @secret)}")
    |> Webhook.call(@opts)
  end

  defp stored, do: Ash.read!(WebhookEvent, authorize?: false)

  defp work,
    do: Oban.drain_queue(queue: :mishka_pay_inbox, with_scheduled: true, with_recursion: true)

  test "an event is stored once, however often the provider sends it, and its job is queued" do
    assert deliver(%{"id" => "evt_once"}).status == 200
    assert deliver(%{"id" => "evt_once"}).status == 200

    assert [%{event_id: "evt_once", provider: "stripe", tenant: "site-a", status: :pending}] =
             stored()

    assert_enqueued(worker: WebhookEvent.MishkaPayWorker)
  end

  test "a job hands the stored event to the host and marks it processed" do
    MishkaPay.Test.start_plugin!(EventWorker)
    deliver(%{"id" => "evt_work", "type" => "payment_intent.succeeded"})

    assert %{success: 1, failure: 0} = work()

    assert_received {:processing,
                     %Event{
                       id: "evt_work",
                       type: "payment_intent.succeeded",
                       tenant: "site-a",
                       provider: "stripe"
                     }}

    assert [%{status: :processed, processed_at: %DateTime{}, last_error: nil}] = stored()
  end

  test "an event the host cannot work is tried again, then marked failed with the reason" do
    MishkaPay.Test.start_plugin!(EventWorker)
    deliver(%{"id" => "evt_fail", "type" => "work.fails"})

    work()

    assert [%{status: :failed, last_error: last_error}] = stored()
    assert last_error == "the event was not processed: the store is down"
  end

  test "a failed try keeps its reason on the row while the event is still tried again" do
    MishkaPay.Test.start_plugin!(EventWorker)
    deliver(%{"id" => "evt_retry", "type" => "work.fails"})

    Oban.drain_queue(queue: :mishka_pay_inbox)

    assert [%{status: :pending, last_error: "the event was not processed: the store is down"}] =
             stored()
  end

  test "with no host listener the event is still worked and marked processed" do
    deliver(%{"id" => "evt_nobody"})
    work()

    assert [%{status: :processed}] = stored()
  end
end

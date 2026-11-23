# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Ash.InboxTest do
  # Starts plugins and shares the sandboxed database with their tasks.
  use MishkaPay.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  require Ecto.Query

  alias MishkaPay.{Event, Webhook}
  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Support.{EventWorker, WebhookEvent, WebhookRejection}
  alias MishkaPay.Support.WebhookEvent.MishkaPayAnswerListener, as: InboxAnswer
  alias MishkaPay.Support.WebhookEvent.MishkaPayListener, as: Inbox
  alias MishkaPay.Support.WebhookRejection.MishkaPayListener, as: Rejections

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

  test "the inbox row keeps when its webhook came in and how long it took to answer" do
    MishkaPay.Test.start_plugin!(InboxAnswer)
    ref = :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :webhook, :answered]])
    before = DateTime.utc_now()

    assert deliver(%{"id" => "evt_timed"}).status == 200

    assert_received {[:mishka_pay, :webhook, :answered], ^ref, %{answer_ms: answer_ms},
                     %{status: 200, outcome: :ok, tenant: "site-a", id: "evt_timed"}}

    assert [%{event_id: "evt_timed", answer_ms: ^answer_ms, answer_status: 200} = row] = stored()
    assert DateTime.compare(row.received_at, before) != :lt
    assert answer_ms >= 0
  end

  test "Mishka Pay's listeners of a domain include the inbox's answer listener and the rejection counter" do
    listeners = MishkaPay.Ash.listeners(MishkaPay.Support.Domain)
    assert Inbox in listeners and InboxAnswer in listeners and Rejections in listeners
    assert MishkaPay.Ash.Resource.Info.listeners(WebhookEvent) == [Inbox, InboxAnswer]
  end

  test "refused messages are counted per provider, site, reason and day, and never stored" do
    MishkaPay.Test.start_plugin!(Rejections)
    MishkaPay.Test.start_plugin!(InboxAnswer)
    ref = :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :webhook, :answered]])

    body = JSON.encode!(Map.put(@event, "id", "evt_forged"))
    time = System.system_time(:second)

    forged = fn path ->
      conn(:post, path, body)
      |> put_req_header("stripe-signature", "t=#{time},v1=#{String.duplicate("0", 64)}")
      |> Webhook.call(@opts)
    end

    assert forged.("/pay/webhooks/stripe/site-a").status == 400
    assert forged.("/pay/webhooks/stripe/site-a").status == 400
    assert forged.("/pay/webhooks/stripe/no-such-site").status == 400
    assert forged.("/pay/webhooks/stripe/another-unknown").status == 400
    assert forged.("/pay/webhooks/acme-not-installed/site-a").status == 404

    for _five <- 1..5 do
      assert_received {[:mishka_pay, :webhook, :answered], ^ref, %{answer_ms: _}, %{status: _}}
    end

    assert stored() == []
    today = Date.utc_today()

    assert [
             %{
               provider: "stripe",
               tenant: nil,
               reason: "missing_credentials",
               count: 2,
               day: ^today
             },
             %{provider: "stripe", tenant: "site-a", reason: "mismatch", count: 2, day: ^today}
           ] =
             WebhookRejection
             |> Ash.read!(authorize?: false)
             |> Enum.sort_by(&{&1.tenant || "", &1.reason})
  end

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

  test "a failed event is skipped with who and why, is never tried again, and is brought back as failed" do
    MishkaPay.Test.start_plugin!(EventWorker)
    ref = :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :inbox, :skipped]])
    deliver(%{"id" => "evt_skip", "type" => "work.fails"})
    Oban.drain_queue(queue: :mishka_pay_inbox)

    assert [
             %{status: :pending, last_error: "the event was not processed: the store is down"} =
               event
           ] = stored()

    reason = "  " <> String.duplicate("a", 250) <> "  "

    assert {:ok, %{status: :skipped, skipped_by_id: "user-1", skip_reason: kept} = skipped} =
             Ash.update(event, %{reason: reason, by: "user-1"},
               action: :skip,
               authorize?: false
             )

    assert String.length(kept) == 200
    assert %DateTime{} = skipped.skipped_at

    assert_received {[:mishka_pay, :inbox, :skipped], ^ref, %{count: 1},
                     %{event_id: "evt_skip", tenant: "site-a"}}

    work()
    assert [%{status: :skipped}] = stored()

    assert {:ok, %{status: :failed, skipped_at: nil, skipped_by_id: nil, skip_reason: nil} = back} =
             Ash.update(skipped, %{}, action: :bring_back, authorize?: false)

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(back, %{}, action: :bring_back, authorize?: false)
  end

  test "a processed or waiting event cannot be skipped, and a blank reason is kept as none" do
    MishkaPay.Test.start_plugin!(EventWorker)
    deliver(%{"id" => "evt_fine", "type" => "payment_intent.succeeded"})
    [waiting] = stored()

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(waiting, %{}, action: :skip, authorize?: false)

    work()
    [processed] = stored()

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(processed, %{}, action: :skip, authorize?: false)

    deliver(%{"id" => "evt_bad_blank", "type" => "work.fails"})
    work()
    failed = Enum.find(stored(), &(&1.event_id == "evt_bad_blank"))

    assert {:ok, %{status: :skipped, skip_reason: nil}} =
             Ash.update(failed, %{reason: "   "}, action: :skip, authorize?: false)
  end

  test "a processed event older than the days it is kept is forgotten daily; a failed one stays" do
    MishkaPay.Test.start_plugin!(EventWorker)
    test_pid = self()

    :telemetry.attach_many(
      "inbox-test",
      [[:mishka_pay, :inbox, :process, :stop], [:mishka_pay, :inbox, :failed]],
      fn name, measurements, meta, _config -> send(test_pid, {name, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("inbox-test") end)

    for {id, type} <- [{"evt_old", "x.y"}, {"evt_new", "x.y"}, {"evt_bad", "work.fails"}],
        do: deliver(%{"id" => id, "type" => type})

    work()

    assert_received {[:mishka_pay, :inbox, :process, :stop], %{lag: lag},
                     %{outcome: :processed, tenant: "site-a", provider: "stripe"}}

    assert is_integer(lag) and lag >= 0
    assert_received {[:mishka_pay, :inbox, :process, :stop], _, %{outcome: :retry}}
    assert_received {[:mishka_pay, :inbox, :failed], %{count: 1}, %{event_id: "evt_bad"}}

    old = DateTime.add(DateTime.utc_now(), -31, :day)

    MishkaPay.Support.Repo.update_all(
      Ecto.Query.from(e in "pay_webhook_events", where: e.event_id in ["evt_old", "evt_bad"]),
      set: [processed_at: old]
    )

    assert %{failure: 0, discard: 0} =
             AshOban.Test.schedule_and_run_triggers({WebhookEvent, :forget})

    assert stored() |> Enum.map(& &1.event_id) |> Enum.sort() == ["evt_bad", "evt_new"]
  end

  test "with no host listener the event is still worked and marked processed" do
    deliver(%{"id" => "evt_nobody"})
    work()

    assert [%{status: :processed}] = stored()
  end
end

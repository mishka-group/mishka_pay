# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Ash.SubscriptionTest do
  # Starts plugins and shares the sandboxed database with their tasks; Stripe answers through
  # Stripe's own mock server.
  use MishkaPay.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias MishkaPay.Providers.Stripe
  alias MishkaPay.{Subscription, Webhook}
  alias MishkaPay.Support.{StripeMock, SubscriptionWatcher}
  alias MishkaPay.Support.Subscription.MishkaPayListener, as: SubscriptionSync
  alias MishkaPay.Support.WebhookEvent.MishkaPayListener, as: Inbox

  @moduletag :stripe_mock

  @subscription MishkaPay.Support.Subscription
  @event "test/fixtures/stripe/event.json" |> File.read!() |> JSON.decode!()
  @secret "whsec_test_site_a"

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_a", webhook_secret: @secret})
    MishkaPay.Test.stub_http(&StripeMock.forward/1)
    :ok
  end

  defp sync(attrs \\ %{}) do
    Ash.create(
      @subscription,
      Map.merge(%{provider: "stripe", subscription_id: "sub_123", tenant: "site-a"}, attrs),
      action: :sync,
      authorize?: false
    )
  end

  test "a sync reads the subscription from Stripe and keeps one row for it, announcing the change" do
    MishkaPay.Test.start_plugin!(SubscriptionWatcher)

    assert {:ok, first} = sync()
    assert {:ok, again} = sync(%{tenant: "site-b"})

    assert again.id == first.id
    assert again.tenant == "site-a"
    assert first.provider_id == "sub_123"
    {:ok, live} = MishkaPay.fetch_subscription("stripe", "sub_123", "site-a")
    assert first.status == live.status
    assert [_one] = Ash.read!(@subscription, authorize?: false)
    assert_received {:subscription_changed, %Subscription{id: "sub_123"}, %{id: id}}
    assert id == first.id
  end

  test "cancel at the period's end, resume and cancel now go through Stripe and write its answer" do
    {:ok, row} = sync()
    MishkaPay.Test.start_plugin!(SubscriptionWatcher)

    for {action, args} <- [cancel: %{}, resume: %{}, cancel: %{at: :now}] do
      assert {:ok, %{synced_at: synced_at}} =
               row |> Ash.Changeset.for_update(action, args) |> Ash.update(authorize?: false)

      assert DateTime.compare(synced_at, row.synced_at) in [:gt, :eq]
      assert_received {:subscription_changed, %Subscription{}, _record}
    end

    assert {:error, %Ash.Error.Invalid{}} =
             row
             |> Ash.Changeset.for_update(:cancel, %{at: :tomorrow})
             |> Ash.update(authorize?: false)
  end

  test "change, pause and resume collection go through Stripe and write its answer" do
    {:ok, row} = sync()
    MishkaPay.Test.start_plugin!(SubscriptionWatcher)

    for {action, args} <- [
          change: %{
            item_id: "si_123",
            price_id: "price_123",
            quantity: 2,
            proration: :always_invoice
          },
          pause: %{
            behavior: :keep_as_draft,
            resumes_at: DateTime.add(DateTime.utc_now(), 7, :day)
          },
          resume_collection: %{}
        ] do
      assert {:ok, %{synced_at: _}} =
               row |> Ash.Changeset.for_update(action, args) |> Ash.update(authorize?: false)

      assert_received {:subscription_changed, %Subscription{}, _record}
    end

    assert {:error, %Ash.Error.Invalid{}} =
             row
             |> Ash.Changeset.for_update(:change, %{proration: :sometimes})
             |> Ash.update(authorize?: false)

    assert {:error, %Ash.Error.Invalid{}} =
             row |> Ash.Changeset.for_update(:change, %{}) |> Ash.update(authorize?: false)
  end

  test "a subscription Stripe cannot give is an error, and nothing is written" do
    MishkaPay.Test.put_keys("stripe", %{secret_key: "not-a-key"})

    assert {:error, _error} = sync()
    assert [] = Ash.read!(@subscription, authorize?: false)
  end

  test "a webhook about an invoice reaches the subscription row through the inbox" do
    MishkaPay.Test.start_plugin!(Inbox)
    MishkaPay.Test.start_plugin!(SubscriptionSync)

    body =
      @event
      |> Map.merge(%{"id" => "evt_invoice", "type" => "invoice.paid"})
      |> put_in(["data", "object"], %{
        "id" => "in_1",
        "object" => "invoice",
        "parent" => %{"subscription_details" => %{"subscription" => "sub_123"}}
      })
      |> JSON.encode!()

    time = System.system_time(:second)

    conn =
      conn(:post, "/pay/webhooks/stripe/site-a", body)
      |> put_req_header(
        "stripe-signature",
        "t=#{time},v1=#{Stripe.signature(body, time, @secret)}"
      )
      |> Webhook.call(Webhook.init(at: "/pay/webhooks"))

    assert conn.status == 200
    Oban.drain_queue(queue: :mishka_pay_inbox)

    assert [%{provider_id: "sub_123", tenant: "site-a"}] =
             Ash.read!(@subscription, authorize?: false)
  end
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Ash.DisputeTest do
  # Starts plugins and shares the sandboxed database with their tasks; Stripe answers through
  # Stripe's own mock server.
  use MishkaPay.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias MishkaPay.{Dispute, Webhook}
  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Support.{DisputeSync, DisputeWatcher, Inbox, StripeMock}

  @moduletag :stripe_mock

  @dispute MishkaPay.Support.Dispute
  @event "test/fixtures/stripe/event.json" |> File.read!() |> JSON.decode!()
  @secret "whsec_test_site_a"

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_a", webhook_secret: @secret})
    MishkaPay.Test.stub_http(&StripeMock.forward/1)
    :ok
  end

  defp sync do
    Ash.create(@dispute, %{provider: "stripe", dispute_id: "dp_123", tenant: "site-a"},
      action: :sync,
      authorize?: false
    )
  end

  test "a sync keeps one row per dispute, and evidence and accepting go through Stripe" do
    MishkaPay.Test.start_plugin!(DisputeWatcher)

    assert {:ok, row} = sync()
    assert {:ok, again} = sync()
    assert again.id == row.id
    assert row.tenant == "site-a"
    assert row.status in Dispute.statuses()
    assert_received {:dispute_changed, %Dispute{}, %{id: id}}
    assert id == row.id

    assert {:ok, %{synced_at: _}} =
             row
             |> Ash.Changeset.for_update(:submit_evidence, %{
               evidence: %{uncategorized_text: "Downloaded twice"},
               submit: true
             })
             |> Ash.update(authorize?: false)

    assert {:ok, _accepted} =
             row |> Ash.Changeset.for_update(:accept, %{}) |> Ash.update(authorize?: false)

    assert_received {:dispute_changed, %Dispute{}, _record}
  end

  test "a dispute webhook reaches the dispute row through the inbox" do
    MishkaPay.Test.start_plugin!(Inbox)
    MishkaPay.Test.start_plugin!(DisputeSync)

    body =
      @event
      |> Map.merge(%{"id" => "evt_dispute", "type" => "charge.dispute.created"})
      |> put_in(["data", "object"], %{
        "id" => "dp_123",
        "object" => "dispute",
        "payment_intent" => "pi_123"
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

    assert [%{provider: "stripe", tenant: "site-a"}] = Ash.read!(@dispute, authorize?: false)
  end
end

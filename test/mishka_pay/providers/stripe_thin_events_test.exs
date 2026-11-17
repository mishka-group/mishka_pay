# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.StripeThinEventsTest do
  # Starts the Stripe and listener plugins, which change events every test sees.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias MishkaPay.{Event, Webhook}
  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Support.EventListener

  @secret "whsec_thin_site_a"
  @opts Webhook.init(at: "/pay/webhooks")

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.start_plugin!(EventListener)

    MishkaPay.Test.put_keys(
      "stripe",
      %{secret_key: "sk_test_a", webhook_secret: @secret},
      "site-a"
    )

    :ok
  end

  # Stripe answering the reads of `objects` by path, each in its own shape; stripe-mock knows no
  # API v2. It tells the test each read and the account it was made as.
  defp stripe(objects) do
    test_pid = self()

    MishkaPay.Test.stub_http(fn conn ->
      send(test_pid, {:read, conn.method, conn.request_path, account(conn)})

      case Map.fetch(objects, conn.request_path) do
        {:ok, object} ->
          Req.Test.json(conn, object)

        :error ->
          conn
          |> put_status(404)
          |> Req.Test.json(%{
            "error" => %{"type" => "invalid_request_error", "code" => "resource_missing"}
          })
      end
    end)
  end

  defp account(conn),
    do:
      List.first(get_req_header(conn, "stripe-account") ++ get_req_header(conn, "stripe-context"))

  defp deliver(type, related, opts \\ []) do
    {body, headers} = MishkaPay.Test.signed_thin_event(type, related, @secret, opts)
    post(body, headers)
  end

  defp post(body, headers) do
    headers
    |> Enum.reduce(conn(:post, "/pay/webhooks/stripe/site-a", body), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> Webhook.call(@opts)
  end

  defp related(id, type, url), do: %{"id" => id, "type" => type, "url" => url}

  test "a thin event whose object is the id it names becomes its Event with no request" do
    MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)

    for {type, related, field, id} <- [
          {"v1.payment_intent.succeeded",
           related("pi_1", "payment_intent", "/v1/payment_intents/pi_1"), :payment_id, "pi_1"},
          {"v1.customer.subscription.past_due",
           related("sub_1", "subscription", "/v1/subscriptions/sub_1"), :subscription_id,
           "sub_1"},
          {"v1.product.default_price_changed",
           related("prod_1", "product", "/v1/products/prod_1"), :object_id, "prod_1"}
        ] do
      snapshot_type = String.replace_prefix(type, "v1.", "")
      assert deliver(type, related, id: "evt_test_#{id}").status == 200
      assert_received {:webhook_event, %Event{type: ^snapshot_type, tenant: "site-a"} = event}
      assert Map.fetch!(event, field) == id, "#{type} does not name #{field}"
      assert event.object_type == related["type"]
    end
  end

  test "an id that sits inside the object is read from it, as the event's account" do
    stripe(%{
      "/v1/charges/ch_1" => %{"id" => "ch_1", "object" => "charge", "payment_intent" => "pi_9"},
      "/v1/invoices/in_1" => %{
        "id" => "in_1",
        "object" => "invoice",
        "parent" => %{"subscription_details" => %{"subscription" => "sub_9"}}
      },
      "/v1/customers/cus_linked" => %{
        "id" => "cus_linked",
        "object" => "customer",
        "customer_account" => "acct_buyer"
      },
      "/v1/customers/cus_1" => %{"id" => "cus_1", "object" => "customer"}
    })

    assert deliver("v1.charge.refunded", related("ch_1", "charge", "/v1/charges/ch_1"),
             context: "acct_seller"
           ).status == 200

    assert_received {:read, "GET", "/v1/charges/ch_1", "acct_seller"}

    assert_received {:webhook_event,
                     %Event{
                       type: "charge.refunded",
                       object_id: "ch_1",
                       object_type: "charge",
                       payment_id: "pi_9",
                       account: "acct_seller"
                     }}

    assert deliver(
             "v1.invoice.payment_succeeded",
             related("in_1", "invoice", "/v1/invoices/in_1")
           ).status ==
             200

    assert_received {:read, "GET", "/v1/invoices/in_1", nil}
    assert_received {:webhook_event, %Event{subscription_id: "sub_9", object_id: "in_1"}}

    # A customer made on Accounts v2 sends v1.customer.* about the Customer Stripe links to it;
    # the Event names the account, as the host keeps it.
    for {id, customer_id} <- [{"cus_linked", "acct_buyer"}, {"cus_1", "cus_1"}] do
      assert deliver("v1.customer.updated", related(id, "customer", "/v1/customers/#{id}")).status ==
               200

      assert_received {:read, "GET", "/v1/customers/" <> ^id, nil}

      assert_received {:webhook_event,
                       %Event{type: "customer.updated", object_id: ^id, customer_id: ^customer_id}}
    end
  end

  test "an object gone since is named by its id, and a detached payment method by its old customer" do
    stripe(%{
      "/v2/core/events/evt_test_detached" => %{
        "id" => "evt_test_detached",
        "object" => "v2.core.event",
        "type" => "v1.payment_method.detached",
        "changes" => %{"before" => %{"customer" => "cus_old"}, "after" => %{"customer" => nil}}
      }
    })

    assert deliver("v1.invoice.deleted", related("in_gone", "invoice", "/v1/invoices/in_gone")).status ==
             200

    assert_received {:webhook_event,
                     %Event{object_id: "in_gone", object_type: "invoice", subscription_id: nil}}

    assert deliver(
             "v1.payment_method.detached",
             related("pm_1", "payment_method", "/v1/payment_methods/pm_1"),
             id: "evt_test_detached"
           ).status == 200

    assert_received {:read, "GET", "/v2/core/events/evt_test_detached", nil}
    assert_received {:webhook_event, %Event{object_id: "pm_1", customer_id: "cus_old"}}
  end

  test "a meter's refused reports are an Event about the meter, and an event Mishka Pay does not act on costs no request" do
    MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)

    assert deliver(
             "v1.billing.meter.error_report_triggered",
             related("mtr_1", "billing.meter", "/v1/billing/meters/mtr_1")
           ).status == 200

    assert_received {:webhook_event,
                     %Event{
                       type: "billing.meter.error_report_triggered",
                       object_id: "mtr_1",
                       object_type: "billing.meter"
                     }}

    assert deliver("v1.charge.updated", related("ch_1", "charge", "/v1/charges/ch_1")).status ==
             200

    assert_received {:webhook_event,
                     %Event{type: "charge.updated", object_id: "ch_1", payment_id: nil}}
  end

  test "a thin event carries its snapshot event's type, so one listener takes either mode; API v2's keep Stripe's" do
    stripe(%{
      "/v1/invoices/in_1" => %{
        "id" => "in_1",
        "object" => "invoice",
        "parent" => %{"subscription_details" => %{"subscription" => "sub_1"}}
      }
    })

    assert deliver("v1.invoice.paid", related("in_1", "invoice", "/v1/invoices/in_1")).status ==
             200

    assert_received {:webhook_event,
                     %Event{type: "invoice.paid", subscription_id: "sub_1"} = thin}

    {body, headers} =
      MishkaPay.Test.signed_event(
        "invoice.paid",
        %{
          "id" => "in_1",
          "object" => "invoice",
          "parent" => %{"subscription_details" => %{"subscription" => "sub_1"}}
        },
        @secret
      )

    assert post(body, headers).status == 200
    assert_received {:webhook_event, %Event{type: "invoice.paid"} = snapshot}

    assert Map.take(thin, [:type, :subscription_id, :object_id]) ==
             Map.take(snapshot, [:type, :subscription_id, :object_id])

    assert deliver("v1.invoice.overpaid", related("in_1", "invoice", "/v1/invoices/in_1")).status ==
             200

    assert_received {:webhook_event, %Event{type: "invoice.overpaid"}}
    assert is_map_key(Stripe.event_types(), "invoice.overpaid")

    assert deliver(
             "v2.core.account.updated",
             related("acct_1", "v2.core.account", "/v2/core/accounts/acct_1")
           ).status == 200

    assert_received {:webhook_event, %Event{type: "v2.core.account.updated", account: "acct_1"}}
  end

  test "a site acting for a connected account refuses another account's thin event before any read" do
    MishkaPay.Test.put_keys(
      "stripe",
      %{secret_key: "sk_test_a", webhook_secret: @secret, account_id: "acct_mine"},
      "site-a"
    )

    MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)

    conn =
      deliver("v1.charge.refunded", related("ch_1", "charge", "/v1/charges/ch_1"),
        context: "acct_other"
      )

    assert conn.status == 400
    refute_received {:webhook_event, _event}
  end

  test "a read Stripe refuses leaves the event to be sent again" do
    MishkaPay.Test.stub_http(fn conn ->
      conn
      |> put_status(403)
      |> Req.Test.json(%{"error" => %{"type" => "invalid_request_error", "code" => "forbidden"}})
    end)

    assert deliver("v1.charge.refunded", related("ch_1", "charge", "/v1/charges/ch_1")).status ==
             400

    refute_received {:webhook_event, _event}
  end

  describe "listing and replaying thin events" do
    # API v2's event list, newest first, a page of one then the last page; it tells the test each
    # query as sent.
    defp events_api do
      test_pid = self()

      MishkaPay.Test.stub_http(fn conn ->
        query = URI.decode_query(conn.query_string)
        send(test_pid, {:query, conn.request_path, query})

        case {conn.request_path, query["page"]} do
          {"/v1/charges/ch_1", _page} ->
            Req.Test.json(conn, %{
              "id" => "ch_1",
              "object" => "charge",
              "payment_intent" => "pi_7"
            })

          {"/v2/core/events", nil} ->
            Req.Test.json(conn, %{
              "data" => [
                thin(
                  "evt_test_2",
                  "v1.charge.refunded",
                  related("ch_1", "charge", "/v1/charges/ch_1")
                ),
                thin(
                  "evt_test_x",
                  "v1.issuing_card.created",
                  related("ic_1", "issuing.card", "/v1/issuing/cards/ic_1")
                )
              ],
              "next_page_url" => "/v2/core/events?page=page_2&limit=20"
            })

          {"/v2/core/events", "page_2"} ->
            Req.Test.json(conn, %{
              "data" => [
                thin(
                  "evt_test_1",
                  "v1.payment_intent.succeeded",
                  related("pi_1", "payment_intent", "/v1/payment_intents/pi_1")
                )
              ],
              "next_page_url" => nil
            })
        end
      end)
    end

    defp thin(id, type, related) do
      %{
        "id" => id,
        "object" => "v2.core.event",
        "type" => type,
        "created" => "2026-11-17T12:00:00.000Z",
        "livemode" => false,
        "context" => nil,
        "related_object" => related,
        "snapshot_event" => "evt_snap_#{id}"
      }
    end

    test "a site on thin events lists them from API v2, each the Event its webhook gives" do
      events_api()
      since = ~U[2026-11-17 11:00:00Z]

      assert {:ok, %MishkaPay.Page{items: [refunded, _issuing], has_more: true, next: next}} =
               MishkaPay.list_events("stripe", "site-a",
                 since: since,
                 types: ["charge.refunded", "v1.issuing_card.created"],
                 object_id: "ch_7"
               )

      assert %Event{id: "evt_test_2", payment_id: "pi_7", type: "charge.refunded"} = refunded
      assert_received {:query, "/v2/core/events", query}

      assert %{
               "created[gte]" => "2026-11-17T11:00:00Z",
               "types[0]" => "v1.charge.refunded",
               "types[1]" => "v1.issuing_card.created",
               "object_id" => "ch_7",
               "limit" => "10"
             } = query

      assert {:ok, %MishkaPay.Page{items: [%Event{id: "evt_test_1"}], has_more: false}} =
               MishkaPay.list_events("stripe", "site-a", after: next)

      assert_received {:query, "/v2/core/events", %{"page" => "page_2", "limit" => "20"}}
    end

    test "a replay on thin events delivers only those Mishka Pay maps, oldest first" do
      events_api()

      assert {:ok, %{delivered: 2, failed: []}} =
               MishkaPay.replay_events("stripe", "site-a", since: ~U[2026-11-17 11:00:00Z])

      assert_received {:webhook_event,
                       %Event{id: "evt_test_1", payment_id: "pi_1", tenant: "site-a"}}

      assert_received {:webhook_event, %Event{id: "evt_test_2", payment_id: "pi_7"}}
      refute_received {:webhook_event, %Event{id: "evt_test_x"}}
    end

    test "a site on snapshot events, or a call that asks, reads /v1/events" do
      MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_a", events: :snapshot}, "site-a")
      test_pid = self()

      MishkaPay.Test.stub_http(fn conn ->
        send(test_pid, {:path, conn.request_path})
        Req.Test.json(conn, %{"data" => [], "has_more" => false})
      end)

      assert {:ok, %MishkaPay.Page{items: []}} = MishkaPay.list_events("stripe", "site-a")
      assert_received {:path, "/v1/events"}

      assert {:ok, %MishkaPay.Page{items: []}} =
               MishkaPay.list_events("stripe", "site-a", events: "snapshot")

      assert_received {:path, "/v1/events"}

      assert {:error, %MishkaPay.Errors.Invalid{errors: [%{field: :events}]}} =
               MishkaPay.list_events("stripe", "site-a", events: :fat)

      assert {:error, %MishkaPay.Errors.Invalid{errors: [%{field: :object_id}]}} =
               MishkaPay.list_events("stripe", "site-a", object_id: "cus_1")

      refute_received {:path, _path}
    end
  end
end

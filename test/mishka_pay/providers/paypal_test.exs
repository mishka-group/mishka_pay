# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.PayPalTest do
  # Starts the PayPal plugin, which changes the providers event every test sees.
  use ExUnit.Case, async: false

  alias MishkaPay.{Checkout, Errors, Event, Invoice, Page, Payment, Price, Refund, Subscription}
  alias MishkaPay.Helpers.TokenCache
  alias MishkaPay.Providers.PayPal
  alias MishkaPay.Test.PayPal, as: PayPalStub

  @keys %{
    publishable_key: "client_a",
    secret_key: "secret_a",
    webhook_secret: "WH-1",
    mode: :test
  }

  @checkout %{
    provider: "paypal",
    tenant: "site-a",
    items: [%{name: "Ebook", amount: %{amount: "19.99", currency: "USD"}, quantity: 2}],
    success_url: "https://shop.test/thanks",
    cancel_url: "https://shop.test/cart",
    reference: "order-1",
    customer: %{email: "buyer@shop.test"}
  }

  setup do
    MishkaPay.Test.start_plugin!(PayPal)
    MishkaPay.Test.put_keys("paypal", @keys)
    PayPalStub.stub!()
    TokenCache.drop({:paypal, "client_a", :test})
    :ok
  end

  defp paypal_request(method, path) do
    assert_received {:paypal, ^method, ^path, headers, body}
    {headers, body}
  end

  describe "checkout" do
    test "creates an Order with the items, totals, return URLs and the reference, and answers its page" do
      assert {:ok, %Checkout{id: "ORDER" <> _ = id, status: :open, url: url}} =
               MishkaPay.checkout(@checkout)

      assert url =~ "checkoutnow?token=#{id}"

      {headers, body} = paypal_request("POST", "/v2/checkout/orders")
      assert headers["paypal-request-id"] =~ "mishka_pay-checkout-"
      assert body["intent"] == "CAPTURE"

      assert %{
               "custom_id" => "order-1",
               "amount" => %{"currency_code" => "USD", "value" => "39.98"},
               "items" => [
                 %{"name" => "Ebook", "quantity" => "2", "unit_amount" => %{"value" => "19.99"}}
               ]
             } = hd(body["purchase_units"])

      assert %{
               "return_url" => "https://shop.test/thanks",
               "cancel_url" => "https://shop.test/cart"
             } =
               body["payment_source"]["paypal"]["experience_context"]

      assert body["payment_source"]["paypal"]["email_address"] == "buyer@shop.test"
    end

    test "gets the OAuth token once and keeps it for the next calls" do
      {:ok, _first} = MishkaPay.checkout(@checkout)
      {:ok, _second} = MishkaPay.checkout(%{@checkout | reference: "order-2"})

      assert_received {:paypal, "POST", "/v1/oauth2/token", _headers,
                       %{"grant_type" => "client_credentials"}}

      refute_received {:paypal, "POST", "/v1/oauth2/token", _headers, _body}
    end

    test "what PayPal cannot sell is refused before any request" do
      monthly = %{name: "Pro", amount: %{amount: "9", currency: "USD"}, interval: :month}

      for {attrs, operation} <- [
            {%{mode: :subscription, items: [monthly, %{monthly | name: "Extra"}]},
             "subscription checkout with more than one price"},
            {%{merchant_of_record: true}, "checkout as merchant of record"},
            {%{allow_promotion_codes: true}, "checkout with promotion codes"},
            {%{discounts: [%{coupon_id: "SPRING"}]}, "checkout with discounts"},
            {%{locale: "de"}, "checkout with a page language"},
            {%{automatic_tax: true}, "checkout with automatic tax"},
            {%{invoice: true}, "checkout with an invoice"},
            {%{
               items: [
                 %{
                   name: "Ebook",
                   amount: %{amount: "10", currency: "USD"},
                   tax_behavior: :exclusive
                 }
               ]
             }, "checkout with a tax behavior"},
            {%{items: [%{id: "price_1"}]}, "checkout by a provider price id"},
            {%{items: [%{name: "Ebook", amount: %{amount: "100", currency: "INR"}}]},
             "checkout in INR"},
            {%{items: [%{name: "Ebook", amount: %{amount: "100.50", currency: "TWD"}}]},
             "checkout in TWD"}
          ] do
        assert {:error, %Errors.Unsupported{provider: "paypal", operation: ^operation}} =
                 MishkaPay.checkout(Map.merge(@checkout, attrs))
      end

      refute_received {:paypal, _method, _path, _headers, _body}
    end

    test "a site whose keys PayPal does not take is a rejection, and no token is kept" do
      MishkaPay.Test.put_keys("paypal", %{@keys | publishable_key: "client_bad"})

      assert {:error, %Errors.Rejected{provider: "paypal", status: 401, code: "invalid_client"}} =
               MishkaPay.checkout(@checkout)
    end
  end

  describe "capture and read" do
    test "an approved Order is captured once on return, then reads as a paid payment" do
      PayPalStub.order("ORDER1", "APPROVED")

      assert {:ok, %Checkout{status: :complete, payment_id: "ORDER1", reference: "order-1"}} =
               MishkaPay.fetch_checkout("paypal", "ORDER1", "site-a")

      {headers, _body} = paypal_request("POST", "/v2/checkout/orders/ORDER1/capture")
      assert headers["paypal-request-id"] =~ "mishka_pay-capture-"

      assert {:ok, %Payment{id: "ORDER1", status: :paid} = payment} =
               MishkaPay.fetch_payment("paypal", "ORDER1", "site-a")

      refute_received {:paypal, "POST", "/v2/checkout/orders/ORDER1/capture", _h, _b}
      assert payment.amount == Money.new(:USD, "39.98")

      assert {payment.customer_email, payment.customer_name} ==
               {"buyer@example.com", "Ava Martin"}

      assert payment.payment_method == "paypal"
    end

    test "a capture PayPal declines is a decline" do
      PayPalStub.order("ORDER2", "APPROVED", declined: true)

      assert {:error, %Errors.Declined{provider: "paypal", reason: "INSTRUMENT_DECLINED"}} =
               MishkaPay.fetch_payment("paypal", "ORDER2", "site-a")
    end

    test "a customer cannot be deleted at PayPal: refused before any request" do
      assert {:error, %Errors.Unsupported{provider: "paypal", operation: :customer}} =
               MishkaPay.delete_customer("paypal", "CUSTOMER1", "site-a")

      refute_received {:paypal, _method, _path, _headers, _body}
    end

    test "PayPal has no list of subscriptions: a list or a search is refused before any request" do
      assert {:error, %Errors.Unsupported{provider: "paypal", operation: :subscription_list}} =
               MishkaPay.list_subscriptions("paypal", "site-a", status: :active)

      assert {:error, %Errors.Unsupported{provider: "paypal", operation: :subscription_list}} =
               MishkaPay.search_subscriptions("paypal", "site-a", reference: "order-1")

      refute_received {:paypal, _method, _path, _headers, _body}
    end

    test "PayPal has no credit notes: every credit note call is refused before any request" do
      note = %{provider: "paypal", invoice_id: "INV2-1", amount: %{amount: "5", currency: "USD"}}

      for call <- [
            fn -> MishkaPay.create_credit_note(note) end,
            fn -> MishkaPay.preview_credit_note(note) end,
            fn -> MishkaPay.fetch_credit_note("paypal", "CN1", "site-a") end,
            fn -> MishkaPay.void_credit_note("paypal", "CN1", "site-a") end,
            fn -> MishkaPay.list_credit_notes("paypal", "site-a", invoice_id: "INV2-1") end,
            fn -> MishkaPay.list_credit_note_lines("paypal", "CN1", "site-a") end
          ] do
        assert {:error, %Errors.Unsupported{provider: "paypal", operation: :credit_note}} =
                 call.()
      end

      refute_received {:paypal, _method, _path, _headers, _body}
    end

    test "PayPal keeps no charges between bills: every invoice item call is refused before any request" do
      for call <- [
            fn ->
              MishkaPay.create_invoice_item(%{
                provider: "paypal",
                customer_id: "C1",
                price_id: "P1"
              })
            end,
            fn -> MishkaPay.update_invoice_item(%{provider: "paypal", id: "I1", quantity: 2}) end,
            fn -> MishkaPay.delete_invoice_item("paypal", "I1", "site-a") end,
            fn -> MishkaPay.list_invoice_items("paypal", "site-a", pending: true) end
          ] do
        assert {:error, %Errors.Unsupported{provider: "paypal", operation: :invoice_item}} =
                 call.()
      end

      refute_received {:paypal, _method, _path, _headers, _body}
    end

    test "PayPal has no customer portal: its setups are refused before any request" do
      assert {:error, %Errors.Unsupported{provider: "paypal", operation: :portal}} =
               MishkaPay.create_portal_configuration(%{provider: "paypal", name: "Teams"})

      assert {:error, %Errors.Unsupported{provider: "paypal", operation: :portal}} =
               MishkaPay.list_portal_configurations("paypal", "site-a")

      refute_received {:paypal, _method, _path, _headers, _body}
    end

    test "a decline and a refusal keep PayPal's debug id and error page, never in their words" do
      PayPalStub.order("ORDER3", "APPROVED", declined: true)

      assert {:error, %Errors.Declined{request_id: "f3a1c2b4d5e60", doc_url: doc_url} = declined} =
               MishkaPay.fetch_payment("paypal", "ORDER3", "site-a")

      assert doc_url =~ "#INSTRUMENT_DECLINED"

      assert {:error, %Errors.Rejected{status: 404, request_id: "f3a1c2b4d5e60"} = missing} =
               MishkaPay.fetch_payment("paypal", "ORDER404NOTHERE", "site-a")

      for error <- [declined, missing],
          text <- [Exception.message(error), MishkaPay.Ash.message(error)] do
        refute text =~ "f3a1c2b4d5e60"
        refute text =~ "developer.paypal.com"
      end
    end

    test "an Order's states read as payment statuses" do
      for {status, opts, expected} <- [
            {"PAYER_ACTION_REQUIRED", [], :pending},
            {"VOIDED", [], :canceled},
            {"COMPLETED", [captures: [%{"id" => "C1", "status" => "COMPLETED"}]], :paid},
            {"COMPLETED", [captures: [%{"id" => "C1", "status" => "DECLINED"}]], :failed},
            {"COMPLETED", [captures: [%{"id" => "C1", "status" => "PENDING"}]], :pending},
            {"COMPLETED",
             [
               captures: [%{"id" => "C1", "status" => "PARTIALLY_REFUNDED"}],
               refunds: [
                 %{
                   "id" => "R1",
                   "status" => "COMPLETED",
                   "amount" => %{"currency_code" => "USD", "value" => "10.00"}
                 }
               ]
             ], :partially_refunded}
          ] do
        PayPalStub.order("ORDERS", status, opts)

        assert {:ok, %Payment{status: ^expected}} =
                 MishkaPay.fetch_payment("paypal", "ORDERS", "site-a")
      end
    end

    test "a captured Order says what PayPal took; one not taken yet says nothing" do
      PayPalStub.order("ORDERC", "COMPLETED",
        captures: [
          %{
            "id" => "C1",
            "status" => "COMPLETED",
            "amount" => %{"currency_code" => "USD", "value" => "19.99"}
          }
        ]
      )

      assert {:ok, %Payment{amount_captured: captured}} =
               MishkaPay.fetch_payment("paypal", "ORDERC", "site-a")

      assert captured == Money.new(:USD, "19.99")

      PayPalStub.order("ORDERP", "COMPLETED",
        captures: [
          %{
            "id" => "C2",
            "status" => "PENDING",
            "amount" => %{"currency_code" => "USD", "value" => "19.99"}
          }
        ]
      )

      assert {:ok, %Payment{amount_captured: nil}} =
               MishkaPay.fetch_payment("paypal", "ORDERP", "site-a")
    end

    test "an id that is not a PayPal Order id never reaches a path" do
      assert {:error, %Errors.Invalid{errors: [%{field: :payment_id}]}} =
               MishkaPay.fetch_payment("paypal", "ORDER1/../../v1/x", "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :checkout_id}]}} =
               MishkaPay.fetch_checkout("paypal", "cs_test_1", "site-a")
    end
  end

  describe "refund" do
    setup do
      PayPalStub.order("ORDER3", "COMPLETED",
        captures: [%{"id" => "CAPTUREORDER3", "status" => "COMPLETED"}]
      )
    end

    test "refunds the Order's capture in part, then a site that refunds once refuses another" do
      assert {:ok, %Refund{status: :succeeded, amount: amount}} =
               MishkaPay.refund(%{
                 provider: "paypal",
                 tenant: "site-a",
                 payment_id: "ORDER3",
                 amount: %{amount: "5", currency: "USD"}
               })

      assert amount == Money.new(:USD, "5.00")
      {_headers, body} = paypal_request("POST", "/v2/payments/captures/CAPTUREORDER3/refund")
      assert body == %{"amount" => %{"currency_code" => "USD", "value" => "5.00"}}

      assert {:ok, %Payment{status: :partially_refunded, refunds: [%Refund{}]}} =
               MishkaPay.fetch_payment("paypal", "ORDER3", "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :payment_id}]}} =
               MishkaPay.refund(%{provider: "paypal", tenant: "site-a", payment_id: "ORDER3"})
    end

    test "a site that refunds many times needs a reference, and refunds again with it" do
      MishkaPay.Test.put_keys("paypal", Map.put(@keys, :refunds, :many))

      refund = %{
        provider: "paypal",
        tenant: "site-a",
        payment_id: "ORDER3",
        amount: %{amount: "5", currency: "USD"}
      }

      assert {:error, %Errors.Invalid{errors: [%{field: :reference}]}} = MishkaPay.refund(refund)
      assert {:ok, _first} = MishkaPay.refund(Map.put(refund, :reference, "r-1"))
      assert {:ok, _second} = MishkaPay.refund(Map.put(refund, :reference, "r-2"))

      assert {:ok, %Payment{amount_refunded: refunded}} =
               MishkaPay.fetch_payment("paypal", "ORDER3", "site-a")

      assert refunded == Money.new(:USD, "10.00")
    end
  end

  describe "the owner" do
    test "goes to PayPal with the reference and comes back on the payment and the subscription" do
      {:ok, %Checkout{id: order_id}} = MishkaPay.checkout(Map.put(@checkout, :owner, "user-7"))

      {_headers, body} = paypal_request("POST", "/v2/checkout/orders")
      assert hd(body["purchase_units"])["custom_id"] == "r=order-1&o=user-7"

      PayPalStub.order(order_id, "APPROVED")

      assert {:ok, %Checkout{reference: "order-1", owner: "user-7"}} =
               MishkaPay.fetch_checkout("paypal", order_id, "site-a")

      assert {:ok, %Payment{reference: "order-1", owner: "user-7"}} =
               MishkaPay.fetch_payment("paypal", order_id, "site-a")

      monthly = %{name: "Pro", amount: %{amount: "9", currency: "USD"}, interval: :month}

      {:ok, %Checkout{id: sub_id}} =
        MishkaPay.checkout(
          Map.merge(@checkout, %{mode: :subscription, items: [monthly], owner: "user-7"})
        )

      PayPalStub.subscription(sub_id, "ACTIVE")

      assert {:ok, %Subscription{reference: "order-1", owner: "user-7"}} =
               MishkaPay.fetch_subscription("paypal", sub_id, "site-a")
    end

    test "without one the reference goes alone, and reads back as it was" do
      {:ok, %Checkout{id: id}} = MishkaPay.checkout(%{@checkout | reference: "r=odd&ref"})
      {_headers, body} = paypal_request("POST", "/v2/checkout/orders")
      assert hd(body["purchase_units"])["custom_id"] == "r=odd&ref"

      assert {:ok, %Payment{reference: "r=odd&ref", owner: nil}} =
               MishkaPay.fetch_payment("paypal", id, "site-a")
    end

    test "a reference and owner longer than PayPal keeps are refused before any request" do
      assert {:error, %Errors.Invalid{errors: [%{field: :reference}]}} =
               MishkaPay.checkout(Map.put(@checkout, :owner, String.duplicate("u", 130)))

      refute_received {:paypal, "POST", "/v2/checkout/orders", _headers, _body}
    end
  end

  describe "subscriptions" do
    @monthly %{
      @checkout
      | items: [
          %{name: "Pro", amount: %{amount: "9", currency: "USD"}, interval: :month, quantity: 2}
        ],
        reference: "sub-order-1"
    }

    test "a subscription checkout makes a product, a plan with its trial, and the subscription to approve" do
      assert {:ok, %Checkout{id: "I-" <> _ = id, url: url, status: :open}} =
               MishkaPay.checkout(Map.merge(@monthly, %{mode: :subscription, trial_days: 7}))

      assert url =~ "/webapps/billing/subscriptions?ba_token="

      {_headers, product} = paypal_request("POST", "/v1/catalogs/products")
      assert product == %{"name" => "Pro", "type" => "SERVICE"}

      {headers, plan} = paypal_request("POST", "/v1/billing/plans")
      assert headers["paypal-request-id"] =~ "mishka_pay-plan-"

      assert [
               %{"tenure_type" => "TRIAL", "frequency" => %{"interval_count" => 7}},
               %{
                 "tenure_type" => "REGULAR",
                 "sequence" => 2,
                 "frequency" => %{"interval_unit" => "MONTH", "interval_count" => 1},
                 "pricing_scheme" => %{"fixed_price" => %{"value" => "9.00"}}
               }
             ] = plan["billing_cycles"]

      {_headers, sub} = paypal_request("POST", "/v1/billing/subscriptions")
      assert sub["quantity"] == "2"
      assert sub["custom_id"] == "sub-order-1"
      assert sub["subscriber"] == %{"email_address" => "buyer@shop.test"}
      assert sub["application_context"]["return_url"] == "https://shop.test/thanks"

      assert {:ok, %Checkout{status: :open, subscription_id: nil}} =
               MishkaPay.fetch_checkout("paypal", id, "site-a")
    end

    test "back from PayPal, an approved subscription completes its checkout and reads as active" do
      {:ok, %Checkout{id: id}} = MishkaPay.checkout(Map.put(@monthly, :mode, :subscription))

      PayPalStub.subscription(id, "ACTIVE",
        billing_info: %{
          "next_billing_time" => "2026-12-16T10:00:00Z",
          "last_payment" => %{"time" => "2026-11-16T10:00:00Z"},
          "cycle_executions" => [%{"tenure_type" => "REGULAR", "cycles_completed" => 1}]
        }
      )

      assert {:ok, %Checkout{status: :complete, subscription_id: ^id, reference: "sub-order-1"}} =
               MishkaPay.fetch_checkout("paypal", id, "site-a")

      assert {:ok,
              %Subscription{
                status: :active,
                reference: "sub-order-1",
                current_period_end: period_end,
                items: [%Price{amount: amount, quantity: 2, interval: :month, interval_count: 1}]
              }} = MishkaPay.fetch_subscription("paypal", id, "site-a")

      assert period_end == ~U[2026-12-16 10:00:00Z]
      assert amount == Money.new(:USD, "9.00")

      assert {:ok, %Invoice{status: :draft, amount_due: due}} =
               MishkaPay.upcoming_invoice("paypal", id, "site-a")

      assert due == Money.new(:USD, "18.00")
    end

    test "a subscription in its trial reads as trialing, until the trial ends" do
      {:ok, %Checkout{id: id}} =
        MishkaPay.checkout(Map.merge(@monthly, %{mode: :subscription, trial_days: 7}))

      PayPalStub.subscription(id, "ACTIVE",
        billing_info: %{
          "next_billing_time" => "2026-11-23T10:00:00Z",
          "cycle_executions" => [
            %{"tenure_type" => "TRIAL", "cycles_completed" => 0},
            %{"tenure_type" => "REGULAR", "cycles_completed" => 0}
          ]
        }
      )

      assert {:ok, %Subscription{status: :trialing, trial_end: ~U[2026-11-23 10:00:00Z]}} =
               MishkaPay.fetch_subscription("paypal", id, "site-a")
    end

    test "its bills are its transactions, newest first; one not approved yet has none" do
      {:ok, %Checkout{id: id}} = MishkaPay.checkout(Map.put(@monthly, :mode, :subscription))

      assert {:ok, %Page{items: []}} =
               MishkaPay.list_invoices("paypal", "site-a", subscription_id: id)

      transactions = "/v1/billing/subscriptions/#{id}/transactions"
      refute_received {:paypal, "GET", ^transactions, _headers, _body}

      bill = fn id, time, status ->
        %{
          "id" => id,
          "status" => status,
          "time" => time,
          "amount_with_breakdown" => %{
            "gross_amount" => %{"currency_code" => "USD", "value" => "18.00"}
          }
        }
      end

      PayPalStub.subscription(id, "ACTIVE",
        transactions: [
          bill.("TX1", "2026-11-16T10:00:00Z", "COMPLETED"),
          bill.("TX2", "2026-12-16T10:00:00Z", "DECLINED")
        ]
      )

      assert {:ok, %Page{items: [%Invoice{id: "TX2", status: :uncollectible}, first]}} =
               MishkaPay.list_invoices("paypal", "site-a", subscription_id: id)

      assert %Invoice{id: "TX1", status: :paid, subscription_id: ^id} = first
      assert first.amount_paid == Money.new(:USD, "18.00")
    end

    test "it is canceled at once; a cancel at the period's end and a resume are refused" do
      {:ok, %Checkout{id: id}} = MishkaPay.checkout(Map.put(@monthly, :mode, :subscription))
      PayPalStub.subscription(id, "ACTIVE")

      assert {:error,
              %Errors.Unsupported{operation: "canceling a subscription at the period's end" <> _}} =
               MishkaPay.cancel_subscription("paypal", id, "site-a")

      assert {:ok, %Subscription{status: :canceled, canceled_at: %DateTime{}}} =
               MishkaPay.cancel_subscription("paypal", id, "site-a", at: :now)

      assert {:error, %Errors.Unsupported{}} =
               MishkaPay.resume_subscription("paypal", id, "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :subscription_id}]}} =
               MishkaPay.upcoming_invoice("paypal", id, "site-a")
    end

    test "one the buyer never approved is not canceled, and the error says why" do
      {:ok, %Checkout{id: id}} = MishkaPay.checkout(Map.put(@monthly, :mode, :subscription))

      assert {:error, %Errors.Invalid{errors: [%{field: :subscription_id, message: message}]}} =
               MishkaPay.cancel_subscription("paypal", id, "site-a", at: :now)

      assert message =~ "has not approved this subscription"
    end

    test "an id that is not a PayPal subscription id never reaches a path" do
      for id <- ["I-../../v1/x", "sub_123", "I-"] do
        assert {:error, %Errors.Invalid{errors: [%{field: :subscription_id}]}} =
                 MishkaPay.fetch_subscription("paypal", id, "site-a")
      end
    end
  end

  describe "webhooks" do
    @event %{
      "id" => "WH-EVT-1",
      "event_type" => "PAYMENT.CAPTURE.COMPLETED",
      "resource_type" => "capture",
      "create_time" => "2026-11-16T10:00:00Z",
      "resource" => %{
        "id" => "CAPTURE1",
        "supplementary_data" => %{"related_ids" => %{"order_id" => "ORDER9"}}
      }
    }

    defp headers(signature) do
      [
        {"paypal-auth-algo", "SHA256withRSA"},
        {"paypal-cert-url", "https://api.sandbox.paypal.com/v1/notifications/certs/CERT"},
        {"paypal-transmission-id", "T1"},
        {"paypal-transmission-sig", signature},
        {"paypal-transmission-time", "2026-11-16T10:00:00Z"}
      ]
    end

    test "PayPal checks the message, and the event names its Order" do
      {:ok, keys} = MishkaPay.Credentials.fetch("paypal", "site-a")

      assert {:ok,
              %Event{
                id: "WH-EVT-1",
                type: "PAYMENT.CAPTURE.COMPLETED",
                payment_id: "ORDER9",
                livemode: false
              }} =
               PayPal.verify_webhook(JSON.encode!(@event), headers("good"), keys)

      {_headers, body} = paypal_request("POST", "/v1/notifications/verify-webhook-signature")
      assert body["webhook_id"] == "WH-1"
      assert body["webhook_event"]["id"] == "WH-EVT-1"
    end

    test "the event goes back to PayPal byte for byte, as PayPal signed it" do
      {:ok, keys} = MishkaPay.Credentials.fetch("paypal", "site-a")

      payload =
        ~s({"resource_type":"capture","id":"WH-EVT-2","event_type":"PAYMENT.CAPTURE.COMPLETED",) <>
          ~s( "create_time":"2026-11-16T10:00:00Z","resource":{"id":"CAPTURE1","amount":{"value":"1.50"}}})

      assert {:ok, %Event{id: "WH-EVT-2"}} = PayPal.verify_webhook(payload, headers("good"), keys)

      assert_received {:paypal_raw, "/v1/notifications/verify-webhook-signature", sent}
      assert String.ends_with?(sent, ~s("webhook_event":) <> payload <> "}")
      assert %{"webhook_id" => "WH-1", "transmission_sig" => "good"} = JSON.decode!(sent)
    end

    test "a message PayPal does not confirm, one without its headers, and a site without a webhook id are refused" do
      {:ok, keys} = MishkaPay.Credentials.fetch("paypal", "site-a")
      payload = JSON.encode!(@event)

      assert {:error, %Errors.BadSignature{reason: :mismatch}} =
               PayPal.verify_webhook(payload, headers("forged"), keys)

      assert {:error, %Errors.BadSignature{reason: :missing_header}} =
               PayPal.verify_webhook(payload, [], keys)

      assert {:error, %Errors.BadSignature{reason: :no_secret}} =
               PayPal.verify_webhook(payload, headers("good"), %{keys | webhook_secret: nil})

      assert {:error, %Errors.BadSignature{reason: :malformed}} =
               PayPal.verify_webhook("not json", headers("good"), keys)
    end

    test "a subscription's own events and its renewals' sales name the subscription" do
      {:ok, keys} = MishkaPay.Credentials.fetch("paypal", "site-a")

      for {type, resource_type, resource} <- [
            {"BILLING.SUBSCRIPTION.ACTIVATED", "subscription", %{"id" => "I-SUB42AAAA"}},
            {"PAYMENT.SALE.COMPLETED", "sale",
             %{"id" => "SALE1", "billing_agreement_id" => "I-SUB42AAAA"}}
          ] do
        event = %{
          @event
          | "event_type" => type,
            "resource_type" => resource_type,
            "resource" => resource
        }

        assert {:ok, %Event{subscription_id: "I-SUB42AAAA", payment_id: nil}} =
                 PayPal.verify_webhook(JSON.encode!(event), headers("good"), keys)
      end
    end
  end
end

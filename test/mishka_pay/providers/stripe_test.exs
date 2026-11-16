# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.StripeTest do
  # Starts the Stripe plugin, which changes the providers event every test sees.
  use ExUnit.Case, async: false

  alias MishkaPay.{Checkout, Errors, Invoice, Payment, Refund, Subscription}
  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Support.StripeMock

  @checkout %{
    provider: "stripe",
    tenant: "site-a",
    items: [%{name: "Ebook", amount: %{amount: "19.99", currency: "USD"}, quantity: 2}],
    success_url: "https://shop.test/thanks",
    cancel_url: "https://shop.test/cart",
    reference: "order-1",
    customer: %{email: "buyer@shop.test"}
  }

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_123"})
    :ok
  end

  describe "against Stripe's mock server" do
    @describetag :stripe_mock

    setup do
      MishkaPay.Test.stub_http(&StripeMock.forward/1)
    end

    test "a checkout opens a Checkout Session that Stripe's spec accepts, and answers its page" do
      assert {:ok,
              %Checkout{id: "cs_" <> _, url: "https://checkout.stripe.com/" <> _, status: :open}} =
               MishkaPay.checkout(@checkout)
    end

    test "a subscription checkout sends recurring prices and its trial as Stripe's spec accepts" do
      monthly = %{name: "Pro plan", amount: %{amount: "9", currency: "USD"}, interval: :month}

      assert {:ok, %Checkout{id: "cs_" <> _, mode: :subscription}} =
               MishkaPay.checkout(
                 Map.merge(@checkout, %{mode: :subscription, items: [monthly], trial_days: 14})
               )

      params =
        Stripe.Mapper.checkout_params(%Checkout{
          provider: "stripe",
          mode: :subscription,
          trial_days: 14,
          reference: "sub-1",
          items: [
            %MishkaPay.Price{
              name: "Pro plan",
              amount: Money.new(:USD, "9"),
              interval: :year,
              interval_count: 1,
              quantity: 1
            }
          ],
          success_url: "https://shop.test/ok",
          cancel_url: "https://shop.test/no"
        })

      assert params["mode"] == "subscription"
      assert params["subscription_data"]["trial_period_days"] == 14
      assert params["subscription_data"]["metadata"] == %{"mishka_pay_reference" => "sub-1"}
      refute Map.has_key?(params, "payment_intent_data")

      assert [%{"price_data" => %{"recurring" => %{"interval" => "year", "interval_count" => 1}}}] =
               params["line_items"]
    end

    test "a subscription is read, cancelled at the period's end or now, resumed, and its invoices listed" do
      assert {:ok, %Subscription{id: "sub_" <> _, provider: "stripe"}} =
               MishkaPay.fetch_subscription("stripe", "sub_123", "site-a")

      assert {:ok, %Subscription{}} = MishkaPay.cancel_subscription("stripe", "sub_123", "site-a")

      assert {:ok, %Subscription{}} =
               MishkaPay.cancel_subscription("stripe", "sub_123", "site-a", at: :now)

      assert {:ok, %Subscription{}} = MishkaPay.resume_subscription("stripe", "sub_123", "site-a")

      assert {:ok, [%Invoice{id: "in_" <> _} | _]} =
               MishkaPay.invoices("stripe", "sub_123", "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :subscription_id}]}} =
               MishkaPay.fetch_subscription("stripe", "pi_123", "site-a")
    end

    test "a checkout is read back by its session id, and a bad id never reaches a path" do
      assert {:ok, %Checkout{id: "cs_" <> _, provider: "stripe"}} =
               MishkaPay.fetch_checkout("stripe", "cs_test_123", "site-a")

      assert {:error, %Errors.Invalid{}} =
               MishkaPay.fetch_checkout("stripe", "cs_1/../../v1/charges", "site-a")
    end

    test "a tax code and the merchant-of-record choice are sent as Stripe expects" do
      ebook = [
        %{name: "Ebook", amount: %{amount: "19.99", currency: "USD"}, tax_code: "txcd_10302000"}
      ]

      assert {:ok, %Checkout{status: :open}} =
               MishkaPay.checkout(Map.merge(@checkout, %{items: ebook, merchant_of_record: true}))

      params =
        Stripe.Mapper.checkout_params(%MishkaPay.Checkout{
          provider: "stripe",
          success_url: "https://shop.test/thanks",
          cancel_url: "https://shop.test/cart",
          items: [
            %MishkaPay.Price{
              name: "Ebook",
              amount: Money.new(:USD, "1"),
              quantity: 1,
              tax_code: "txcd_10302000"
            }
          ],
          merchant_of_record: false
        })

      assert params["managed_payments"] == %{"enabled" => false}

      defaults = %{params_checkout() | merchant_of_record: nil}
      assert Stripe.Mapper.checkout_params(defaults)["managed_payments"] == nil

      assert Stripe.Mapper.checkout_params(defaults, %{merchant_of_record: false})[
               "managed_payments"
             ] ==
               %{"enabled" => false}

      assert Stripe.Mapper.checkout_params(%{defaults | merchant_of_record: true}, %{
               merchant_of_record: false
             })[
               "managed_payments"
             ] == %{"enabled" => true}

      assert get_in(params, ["line_items", Access.at(0), "price_data", "product_data", "tax_code"]) ==
               "txcd_10302000"
    end

    test "a known price and an existing customer are accepted the same way" do
      assert {:ok, %Checkout{}} =
               MishkaPay.checkout(%{
                 @checkout
                 | items: [%{id: "price_123", quantity: 1}],
                   customer: %{id: "cus_123"}
               })
    end

    test "a payment whose last try failed is read as failed, with its money" do
      assert {:ok, %Payment{id: "pi_123", provider: "stripe", status: :failed} = payment} =
               MishkaPay.fetch_payment("stripe", "pi_123", "site-a")

      assert %Money{currency: :USD} = payment.amount
      assert %DateTime{} = payment.created_at
    end

    test "a refund, whole or in part, comes back as Stripe made it" do
      assert {:ok, %Refund{id: "re_" <> _, status: :succeeded}} =
               MishkaPay.refund(%{provider: "stripe", tenant: "site-a", payment_id: "pi_123"})

      assert {:ok, %Refund{status: :succeeded}} =
               MishkaPay.refund(%{
                 provider: "stripe",
                 tenant: "site-a",
                 payment_id: "pi_123",
                 amount: %{amount: "5.00", currency: "USD"},
                 reason: :requested_by_customer
               })
    end

    # Stripe's own PaymentIntent fixture, with only the fields that tell the statuses apart changed.
    test "a payment's status follows Stripe's intent and its charge's refunds" do
      {:ok, %{body: intent}} =
        Req.get("http://localhost:12111/v1/payment_intents/pi_123?expand[]=latest_charge",
          auth: {:bearer, "sk_test_123"}
        )

      paid = %{intent | "status" => "succeeded"}
      charge = paid["latest_charge"]

      for {changed, status} <- [
            {paid |> put_in(["latest_charge"], %{charge | "amount_refunded" => 0}), :paid},
            {paid |> put_in(["latest_charge"], %{charge | "amount_refunded" => 500}),
             :partially_refunded},
            {paid |> put_in(["latest_charge"], %{charge | "amount_refunded" => intent["amount"]}),
             :refunded},
            {%{intent | "status" => "requires_action"}, :requires_action},
            {%{intent | "status" => "processing"}, :pending},
            {%{intent | "status" => "requires_payment_method", "last_payment_error" => nil},
             :pending},
            {%{intent | "status" => "canceled"}, :canceled}
          ] do
        assert {:ok, %Payment{status: ^status}} = Stripe.Mapper.payment(changed)
      end
    end

    test "a whole refund of a payment with nothing left is refused before Stripe, many or once" do
      test = self()

      MishkaPay.Test.stub_http(fn
        %{method: "GET"} = conn ->
          {:ok, %{body: intent}} =
            Req.get("http://localhost:12111#{conn.request_path}?#{conn.query_string}",
              auth: {:bearer, "sk_test_123"}
            )

          Req.Test.json(
            conn,
            put_in(intent, ["latest_charge", "amount_refunded"], intent["amount"])
          )

        conn ->
          send(test, :refund_sent)
          StripeMock.forward(conn)
      end)

      MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_123", refunds: :many})

      assert {:error, %Errors.Invalid{errors: [%{field: :payment_id, message: message}]}} =
               MishkaPay.refund(%{
                 provider: "stripe",
                 tenant: "site-a",
                 payment_id: "pi_123",
                 reference: "r-9"
               })

      assert message =~ "nothing is left to refund"
      refute_received :refund_sent
    end

    test "a site that refunds once is refused a second refund; one that refunds many is not" do
      test = self()

      MishkaPay.Test.stub_http(fn
        %{method: "GET"} = conn ->
          {:ok, %{body: intent}} =
            Req.get("http://localhost:12111#{conn.request_path}?#{conn.query_string}",
              auth: {:bearer, "sk_test_123"}
            )

          Req.Test.json(conn, put_in(intent, ["latest_charge", "amount_refunded"], 500))

        conn ->
          send(test, :refund_sent)
          StripeMock.forward(conn)
      end)

      assert {:error, %Errors.Invalid{errors: [%{field: :payment_id}]}} =
               MishkaPay.refund(%{provider: "stripe", tenant: "site-a", payment_id: "pi_123"})

      refute_received :refund_sent

      MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_123", refunds: :many})

      assert {:error, %Errors.Invalid{errors: [%{field: :reference}]}} =
               MishkaPay.refund(%{provider: "stripe", tenant: "site-a", payment_id: "pi_123"})

      refute_received :refund_sent

      assert {:ok, %Refund{status: :succeeded}} =
               MishkaPay.refund(%{
                 provider: "stripe",
                 tenant: "site-a",
                 payment_id: "pi_123",
                 amount: %{amount: "1", currency: "USD"},
                 reference: "refund-2"
               })

      assert_received :refund_sent
    end

    test "many refunds: the same reference sends the same key, another reference another one" do
      MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_123", refunds: "many"})
      ref = :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :request, :start]])

      for reference <- ["r-1", "r-1", "r-2"],
          do:
            MishkaPay.refund(%{
              provider: "stripe",
              tenant: "site-a",
              payment_id: "pi_123",
              reference: reference
            })

      keys =
        for _call <- 1..3 do
          assert_received {_, ^ref, _, %{path: "/v1/refunds", idempotency_key: key}}
          key
        end

      assert [same, same, other] = keys
      refute same == other
    end

    test "refunding once: two refunds of one payment sent at once carry one key, so Stripe makes one" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :request, :start]])

      for _twice <- 1..2,
          do: MishkaPay.refund(%{provider: "stripe", tenant: "site-a", payment_id: "pi_123"})

      keys =
        for _call <- 1..2 do
          assert_received {_, ^ref, _, %{path: "/v1/refunds", idempotency_key: key}}
          key
        end

      assert ["mishka_pay-refund-" <> _digest = same, same] = keys
    end

    test "a part refund in another currency or over what is left is refused before Stripe" do
      for amount <- [%{amount: "5", currency: "EUR"}, %{amount: "11", currency: "USD"}] do
        assert {:error, %Errors.Invalid{errors: [%{field: :amount}]}} =
                 MishkaPay.refund(%{
                   provider: "stripe",
                   tenant: "site-a",
                   payment_id: "pi_123",
                   amount: amount
                 })
      end
    end

    test "Stripe's limits on three-decimal currencies and metadata are kept before any request" do
      kwd = %{@checkout | items: [%{name: "Ebook", amount: %{amount: "1.234", currency: "KWD"}}]}
      assert {:error, %Errors.Invalid{errors: [%{field: :amount}]}} = MishkaPay.checkout(kwd)

      assert {:ok, _checkout} =
               MishkaPay.checkout(%{
                 @checkout
                 | items: [%{name: "Ebook", amount: %{amount: "1.230", currency: "KWD"}}]
               })

      many = Map.new(1..50, &{"k#{&1}", "v"})

      assert {:error, %Errors.Invalid{errors: [%{field: :metadata}]}} =
               MishkaPay.checkout(Map.put(@checkout, :metadata, many))
    end

    test "keys Stripe does not accept are a rejection with its status" do
      MishkaPay.Test.put_keys("stripe", %{secret_key: "not-a-key"})

      assert {:error, %Errors.Rejected{provider: "stripe", status: 401}} =
               MishkaPay.fetch_payment("stripe", "pi_123", "site-a")
    end

    test "the same reference sends the same idempotency key, another reference another one" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :request, :start]])

      for reference <- ["order-7", "order-7", "order-8"],
          do: MishkaPay.checkout(%{@checkout | reference: reference})

      keys =
        for _call <- 1..3 do
          assert_received {_, ^ref, _, %{path: "/v1/checkout/sessions", idempotency_key: key}}
          key
        end

      assert [same, same, other] = keys
      refute same == other
    end
  end

  describe "before any request" do
    test "an id that is not a Stripe id never reaches a path" do
      assert {:error, %Errors.Invalid{errors: [%{field: :payment_id}]}} =
               MishkaPay.fetch_payment("stripe", "pi_1/../../v1/charges", "site-a")
    end

    test "an id of another kind is refused before Stripe: a checkout id is not a payment id" do
      assert {:error, %Errors.Invalid{errors: [%{field: :payment_id, message: message}]}} =
               MishkaPay.fetch_payment("stripe", "cs_test_123", "site-a")

      assert message =~ "pi_"

      assert {:error, %Errors.Invalid{errors: [%{field: :checkout_id}]}} =
               MishkaPay.fetch_checkout("stripe", "pi_123", "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :payment_id}]}} =
               MishkaPay.refund(%{provider: "stripe", tenant: "site-a", payment_id: "ch_123"})
    end

    test "a currency Stripe counts differently from ISO 4217 is refused, not charged wrong" do
      huf = %{@checkout | items: [%{name: "Ebook", amount: %{amount: "1000", currency: "HUF"}}]}

      assert {:error, %Errors.Unsupported{provider: "stripe", operation: "checkout in HUF"}} =
               MishkaPay.checkout(huf)
    end

    test "Stripe's 402 for a card it declined is a decline with Stripe's code" do
      MishkaPay.Test.stub_http(fn conn ->
        conn
        |> Plug.Conn.put_status(402)
        |> Req.Test.json(%{
          "error" => %{
            "type" => "card_error",
            "code" => "card_declined",
            "decline_code" => "insufficient_funds",
            "message" => "Your card has insufficient funds."
          }
        })
      end)

      assert {:error, %Errors.Declined{provider: "stripe", reason: "insufficient_funds"}} =
               MishkaPay.refund(%{provider: "stripe", tenant: "site-a", payment_id: "pi_123"})
    end
  end

  test "a payment brings its buyer, card, receipt, failure and every refund, and keeps the reference out of metadata" do
    intent = %{
      "id" => "pi_full",
      "amount" => 4900,
      "currency" => "usd",
      "status" => "succeeded",
      "description" => "1 × LiveView course",
      "metadata" => %{"mishka_pay_reference" => "course-1", "channel" => "web"},
      "customer" => %{"id" => "cus_1", "email" => "ava@example.com", "name" => "Ava Martin"},
      "latest_charge" => %{
        "amount_refunded" => 1000,
        "receipt_url" => "https://pay.stripe.com/receipts/r_1",
        "billing_details" => %{"email" => "billing@example.com", "name" => "Billing Name"},
        "payment_method_details" => %{
          "type" => "card",
          "card" => %{"brand" => "mastercard", "last4" => "4444"}
        },
        "refunds" => %{
          "data" => [
            %{
              "id" => "re_1",
              "amount" => 1000,
              "currency" => "usd",
              "status" => "succeeded",
              "reason" => "requested_by_customer",
              "created" => 1_794_000_000
            },
            %{
              "id" => "re_odd",
              "amount" => 1,
              "currency" => "usd",
              "reason" => "expired_uncaptured_charge"
            }
          ]
        }
      }
    }

    assert {:ok, payment} = Stripe.Mapper.payment(intent)
    assert payment.status == :partially_refunded
    assert {payment.customer_email, payment.customer_name} == {"ava@example.com", "Ava Martin"}

    assert {payment.payment_method, payment.card_brand, payment.card_last4} ==
             {"card", "mastercard", "4444"}

    assert payment.receipt_url == "https://pay.stripe.com/receipts/r_1"
    assert payment.metadata == %{"channel" => "web"}
    assert payment.description == "1 × LiveView course"

    assert [
             %Refund{
               id: "re_1",
               reason: :requested_by_customer,
               status: :succeeded,
               payment_id: "pi_full"
             },
             %Refund{id: "re_odd", reason: nil}
           ] = payment.refunds

    declined = %{
      "id" => "pi_declined",
      "amount" => 1999,
      "currency" => "usd",
      "status" => "requires_payment_method",
      "customer" => "cus_2",
      "last_payment_error" => %{
        "code" => "card_declined",
        "decline_code" => "insufficient_funds",
        "message" => "Your card has insufficient funds."
      }
    }

    assert {:ok, failed} = Stripe.Mapper.payment(declined)
    assert {failed.status, failed.customer_id, failed.refunds} == {:failed, "cus_2", []}

    assert {failed.failure_code, failed.failure_message} ==
             {"insufficient_funds", "Your card has insufficient funds."}
  end

  test "a subscription brings its status, items, period, cancel, trial, buyer and reference" do
    sub = %{
      "id" => "sub_1",
      "status" => "trialing",
      "customer" => %{"id" => "cus_1", "email" => "ava@example.com", "name" => "Ava Martin"},
      "cancel_at_period_end" => true,
      "cancel_at" => 1_796_000_000,
      "trial_end" => 1_795_000_000,
      "latest_invoice" => "in_1",
      "metadata" => %{"mishka_pay_reference" => "pro-1", "plan" => "pro"},
      "created" => 1_794_000_000,
      "items" => %{
        "data" => [
          %{
            "quantity" => 2,
            "current_period_start" => 1_794_000_000,
            "current_period_end" => 1_796_000_000,
            "price" => %{
              "id" => "price_1",
              "unit_amount" => 900,
              "currency" => "usd",
              "recurring" => %{"interval" => "month", "interval_count" => 1},
              "product" => %{"id" => "prod_1", "name" => "Pro plan"}
            }
          }
        ]
      }
    }

    assert {:ok, %Subscription{} = subscription} = Stripe.Mapper.subscription(sub)
    assert {subscription.status, subscription.cancel_at_period_end} == {:trialing, true}
    assert {subscription.customer_email, subscription.reference} == {"ava@example.com", "pro-1"}
    assert subscription.metadata == %{"plan" => "pro"}
    assert subscription.current_period_end == DateTime.from_unix!(1_796_000_000)
    assert subscription.trial_end == DateTime.from_unix!(1_795_000_000)

    assert [
             %MishkaPay.Price{id: "price_1", name: "Pro plan", interval: :month, quantity: 2} =
               item
           ] =
             subscription.items

    assert item.amount == Money.new(:USD, "9.00")

    assert {:error, %Errors.Invalid{}} =
             Stripe.Mapper.subscription(%{sub | "status" => "something_new"})
  end

  test "an invoice brings its subscription from either place Stripe puts it" do
    invoice = %{
      "id" => "in_1",
      "status" => "paid",
      "currency" => "usd",
      "amount_due" => 900,
      "amount_paid" => 900,
      "period_start" => 1_794_000_000,
      "period_end" => 1_796_000_000,
      "hosted_invoice_url" => "https://invoice.stripe.com/i/1",
      "invoice_pdf" => "https://pay.stripe.com/invoice/1/pdf",
      "parent" => %{"subscription_details" => %{"subscription" => "sub_1"}}
    }

    assert {:ok, %Invoice{status: :paid, subscription_id: "sub_1"} = mapped} =
             Stripe.Mapper.invoice(invoice)

    assert mapped.amount_paid == Money.new(:USD, "9.00")

    assert {:ok, %Invoice{subscription_id: "sub_2"}} =
             invoice
             |> Map.delete("parent")
             |> Map.put("subscription", "sub_2")
             |> Stripe.Mapper.invoice()

    assert {:ok, %MishkaPay.Event{subscription_id: "sub_1", payment_id: nil}} =
             Stripe.Mapper.event(%{
               "id" => "evt_1",
               "type" => "invoice.paid",
               "data" => %{"object" => Map.put(invoice, "object", "invoice")}
             })

    assert {:ok, %MishkaPay.Event{subscription_id: "sub_9"}} =
             Stripe.Mapper.event(%{
               "id" => "evt_2",
               "type" => "customer.subscription.updated",
               "data" => %{"object" => %{"id" => "sub_9", "object" => "subscription"}}
             })
  end

  test "a checkout read back brings its totals and the buyer's email" do
    checkout =
      Stripe.Mapper.checkout(%{
        "id" => "cs_1",
        "status" => "complete",
        "currency" => "usd",
        "amount_total" => 2139,
        "total_details" => %{"amount_tax" => 140},
        "customer_details" => %{"email" => "ava@example.com"},
        "payment_intent" => "pi_1",
        "client_reference_id" => "ebook-1"
      })

    assert checkout.amount_total == Money.new(:USD, "21.39")
    assert checkout.amount_tax == Money.new(:USD, "1.40")
    assert checkout.customer.email == "ava@example.com"
    assert {checkout.payment_id, checkout.reference} == {"pi_1", "ebook-1"}
  end

  test "Stripe's form encoding nests maps and lists and leaves out nil" do
    assert Stripe.form(%{"a" => %{"b" => [%{"c" => 1}, %{"c" => 2}]}, "skip" => nil, "d" => "x"})
           |> Enum.sort() ==
             [{"a[b][0][c]", "1"}, {"a[b][1][c]", "2"}, {"d", "x"}]
  end

  defp params_checkout do
    %MishkaPay.Checkout{
      provider: "stripe",
      success_url: "https://shop.test/thanks",
      cancel_url: "https://shop.test/cart",
      items: [%MishkaPay.Price{name: "Ebook", amount: Money.new(:USD, "1"), quantity: 1}]
    }
  end
end

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

    test "a reference reused with other details is a plain rejection that never shows the key" do
      MishkaPay.Test.stub_http(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => %{
            "type" => "idempotency_error",
            "message" =>
              "Keys for idempotent requests can only be used with the same parameters. Try using a key other than 'mishka_pay-customer-abc'."
          }
        })
      end)

      assert {:error, %Errors.Rejected{status: 400, code: "idempotency_error"} = error} =
               MishkaPay.create_customer(%{
                 provider: "stripe",
                 email: "ava@example.com",
                 reference: "user-1"
               })

      for text <- [Exception.message(error), MishkaPay.Ash.message(error)] do
        assert text =~ "reference was used in the last 24 hours"
        refute text =~ "mishka_pay-customer"
      end
    end

    test "products and prices are made, read, archived and listed as Stripe's spec accepts" do
      assert {:ok, %MishkaPay.Product{id: product_id}} =
               MishkaPay.create_product(%{
                 provider: "stripe",
                 tenant: "site-a",
                 id: "shop-ebook",
                 name: "Ebook",
                 description: "An Elixir ebook",
                 tax_code: "txcd_10302000"
               })

      assert {:ok, %MishkaPay.Price{id: "price_" <> _ = price_id}} =
               MishkaPay.create_price(%{
                 provider: "stripe",
                 tenant: "site-a",
                 product_id: product_id,
                 amount: %{amount: "9.00", currency: "USD"},
                 interval: :month,
                 lookup_key: "pro-monthly"
               })

      assert {:ok, %MishkaPay.Product{}} = MishkaPay.fetch_product("stripe", product_id, "site-a")
      assert {:ok, %MishkaPay.Price{}} = MishkaPay.fetch_price("stripe", price_id, "site-a")

      assert {:ok, %MishkaPay.Product{}} =
               MishkaPay.archive_product("stripe", product_id, "site-a")

      assert {:ok, %MishkaPay.Price{}} = MishkaPay.archive_price("stripe", price_id, "site-a")

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.Product{} | _]}} =
               MishkaPay.list_products("stripe", "site-a", active: true, limit: 2)

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.Price{} | _]}} =
               MishkaPay.list_prices("stripe", "site-a", product_id: product_id, lookup_key: "x")

      assert {:ok, %MishkaPay.Page{items: [%Payment{} | _]}} =
               MishkaPay.list_payments("stripe", "site-a", customer_id: "cus_123")
    end

    test "payment links are made, read, listed and changed as Stripe's spec accepts" do
      assert {:ok, %MishkaPay.PaymentLink{id: "plink_" <> _ = id, url: "https://" <> _}} =
               MishkaPay.create_payment_link(%{
                 provider: "stripe",
                 tenant: "site-a",
                 items: [%{id: "price_123", quantity: 1}],
                 success_url: "https://shop.test/thanks",
                 max_purchases: 1,
                 inactive_message: "Sold out",
                 quantity_min: 1,
                 quantity_max: 3,
                 allow_promotion_codes: true,
                 automatic_tax: true,
                 invoice: true,
                 customer_creation: :always,
                 billing_address: :required,
                 tax_id_collection: true
               })

      assert {:ok, %MishkaPay.PaymentLink{}} =
               MishkaPay.fetch_payment_link("stripe", id, "site-a")

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.PaymentLink{} | _]}} =
               MishkaPay.list_payment_links("stripe", "site-a", active: true)

      assert {:ok, %MishkaPay.PaymentLink{}} =
               MishkaPay.update_payment_link(%{
                 provider: "stripe",
                 tenant: "site-a",
                 id: id,
                 active: false,
                 max_purchases: 10,
                 inactive_message: "Back soon"
               })

      assert {:error, %Errors.Invalid{errors: [%{field: :items}]}} =
               MishkaPay.create_payment_link(%{provider: "stripe", items: [%{id: "prod_1"}]})
    end

    test "a one-time checkout asks for its invoice, and prices carry their tax behavior" do
      inclusive = [
        %{
          name: "Ebook",
          amount: %{amount: "20", currency: "EUR"},
          tax_code: "txcd_10302000",
          tax_behavior: :inclusive
        }
      ]

      assert {:ok, %Checkout{}} =
               MishkaPay.checkout(Map.merge(@checkout, %{items: inclusive, invoice: true}))

      params =
        Stripe.Mapper.checkout_params(%{
          params_checkout()
          | invoice: true,
            items: [
              %MishkaPay.Price{
                name: "E",
                amount: Money.new(:EUR, "20"),
                quantity: 1,
                tax_behavior: :inclusive
              }
            ]
        })

      assert params["invoice_creation"] == %{"enabled" => true}

      assert get_in(params, ["line_items", Access.at(0), "price_data", "tax_behavior"]) ==
               "inclusive"

      refute Map.has_key?(Stripe.Mapper.checkout_params(params_checkout()), "invoice_creation")

      assert {:ok, %MishkaPay.Price{}} =
               MishkaPay.create_price(%{
                 provider: "stripe",
                 product_id: "prod_123",
                 amount: %{amount: "9", currency: "USD"},
                 tax_behavior: :exclusive
               })
    end

    test "the site's automatic tax applies when a checkout or link does not say, and theirs wins" do
      on = %{automatic_tax: true}

      assert Stripe.Mapper.checkout_params(params_checkout(), on)["automatic_tax"] == %{
               "enabled" => true
             }

      refute Map.has_key?(Stripe.Mapper.checkout_params(params_checkout(), %{}), "automatic_tax")

      assert Stripe.Mapper.checkout_params(%{params_checkout() | automatic_tax: false}, on)[
               "automatic_tax"
             ] == %{"enabled" => false}

      link = %MishkaPay.PaymentLink{items: [%MishkaPay.Price{id: "price_1", quantity: 1}]}
      assert Stripe.Mapper.payment_link_params(link, on)["automatic_tax"] == %{"enabled" => true}

      assert %{"restrictions" => %{"completed_sessions" => %{"limit" => 1}}} =
               Stripe.Mapper.payment_link_params(%{link | max_purchases: 1})

      assert %{"line_items" => [%{"adjustable_quantity" => %{"enabled" => true, "maximum" => 4}}]} =
               Stripe.Mapper.payment_link_params(%{link | quantity_max: 4})

      refute Map.has_key?(Stripe.Mapper.payment_link_params(link), "restrictions")

      assert %{"invoice_creation" => %{"enabled" => false}} =
               Stripe.Mapper.payment_link_params(%{link | invoice: false})

      refute Map.has_key?(Stripe.Mapper.payment_link_params(link), "invoice_creation")

      assert %{"managed_payments" => %{"enabled" => false}} =
               Stripe.Mapper.payment_link_params(link, %{merchant_of_record: false})

      assert %{"managed_payments" => %{"enabled" => true}} =
               Stripe.Mapper.payment_link_params(%{link | merchant_of_record: true}, %{
                 merchant_of_record: false
               })
    end

    test "a refusal that names a field says which, never Stripe's own words" do
      MishkaPay.Test.stub_http(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => %{
            "type" => "invalid_request_error",
            "param" => "subscription_data[trial_period_days]",
            "message" => "Trials need a recurring price, plink secret xyz"
          }
        })
      end)

      assert {:error, %Errors.Rejected{param: "subscription_data[trial_period_days]"} = error} =
               MishkaPay.create_payment_link(%{
                 provider: "stripe",
                 items: [%{id: "price_1"}],
                 trial_days: 7
               })

      assert Exception.message(error) ==
               "stripe refused the value of subscription_data[trial_period_days] (HTTP 400)"
    end

    test "a page takes its cursor as Stripe's starting_after, and the next one is its last id" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        send(test, {:query, conn.query_string})

        Req.Test.json(conn, %{
          "object" => "list",
          "has_more" => true,
          "data" => [
            %{"id" => "prod_1", "object" => "product", "name" => "One", "active" => true},
            %{"id" => "prod_2", "object" => "product", "name" => "Two", "active" => true}
          ]
        })
      end)

      assert {:ok, %MishkaPay.Page{items: [_, _], has_more: true, next: "prod_2"}} =
               MishkaPay.list_products("stripe", "site-a", limit: 2, after: "prod_0")

      assert_received {:query, query}
      assert %{"limit" => "2", "starting_after" => "prod_0"} = URI.decode_query(query)
    end

    test "a code already taken and an id Stripe does not have are plain rejections" do
      MishkaPay.Test.stub_http(fn conn ->
        error =
          case conn.request_path do
            "/v1/promotion_codes" ->
              %{
                "type" => "invalid_request_error",
                "message" => "An active promotion code with `code: SPRING` already exists."
              }

            _checkout ->
              %{
                "type" => "invalid_request_error",
                "code" => "resource_missing",
                "message" => "No such coupon: 'NOPE'"
              }
          end

        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => error})
      end)

      assert {:error, %Errors.Rejected{code: "already_exists"} = taken} =
               MishkaPay.create_promotion_code(%{
                 provider: "stripe",
                 coupon_id: "C1",
                 code: "SPRING"
               })

      assert MishkaPay.Ash.message(taken) == "stripe already has one with that code or id"

      assert {:error, %Errors.Rejected{code: "resource_missing"} = missing} =
               MishkaPay.checkout(Map.put(@checkout, :discounts, [%{coupon_id: "NOPE"}]))

      assert Exception.message(missing) == "stripe has nothing with the id given"
    end

    test "a customer is made, changed, read and listed as Stripe's spec accepts, and a portal opened" do
      assert {:ok, %MishkaPay.Customer{id: "cus_" <> _ = id}} =
               MishkaPay.create_customer(%{
                 provider: "stripe",
                 tenant: "site-a",
                 email: "ava@example.com",
                 name: "Ava Martin",
                 reference: "user-1",
                 metadata: %{"plan" => "pro"}
               })

      assert {:ok, %MishkaPay.Customer{}} =
               MishkaPay.update_customer(%{
                 provider: "stripe",
                 tenant: "site-a",
                 id: id,
                 name: "Ava M."
               })

      assert {:ok, %MishkaPay.Customer{id: "cus_" <> _}} =
               MishkaPay.fetch_customer("stripe", id, "site-a")

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.Customer{} | _]}} =
               MishkaPay.list_customers("stripe", "site-a", email: "ava@example.com", limit: 3)

      assert {:ok, %MishkaPay.PortalSession{url: "https://" <> _}} =
               MishkaPay.portal_session(%{
                 provider: "stripe",
                 tenant: "site-a",
                 customer_id: id,
                 return_url: "https://shop.test/account"
               })

      assert {:error, %Errors.Invalid{errors: [%{field: :customer_id}]}} =
               MishkaPay.fetch_customer("stripe", "pi_123", "site-a")
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

      assert {:ok, %MishkaPay.Page{items: [%Invoice{id: "in_" <> _} | _]}} =
               MishkaPay.list_invoices("stripe", "site-a", subscription_id: "sub_123")

      assert {:ok, %MishkaPay.Page{}} =
               MishkaPay.list_invoices("stripe", "site-a", customer_id: "cus_123", after: "in_1")

      assert {:error, %Errors.Invalid{errors: [%{field: :customer_id}]}} =
               MishkaPay.list_invoices("stripe", "site-a", customer_id: "sub_123")

      assert {:error, %Errors.Invalid{errors: [%{field: :subscription_id}]}} =
               MishkaPay.fetch_subscription("stripe", "pi_123", "site-a")
    end

    test "a subscription change, its preview, a pause and an invoice read go as Stripe's spec accepts" do
      change = %{
        provider: "stripe",
        tenant: "site-a",
        subscription_id: "sub_123",
        item_id: "si_123",
        price_id: "price_123",
        quantity: 2,
        proration: :always_invoice,
        billing_cycle_anchor: :unchanged,
        payment_behavior: :error_if_incomplete
      }

      assert {:ok, %Invoice{}} = MishkaPay.preview_subscription_change(change)
      assert {:ok, %Subscription{}} = MishkaPay.change_subscription(change)

      assert {:ok, %Subscription{}} =
               MishkaPay.pause_collection("stripe", "sub_123", "site-a",
                 behavior: :mark_uncollectible,
                 resumes_at: DateTime.add(DateTime.utc_now(), 7, :day)
               )

      assert {:ok, %Subscription{}} = MishkaPay.resume_collection("stripe", "sub_123", "site-a")

      assert {:ok, %Invoice{id: "in_" <> _}} =
               MishkaPay.fetch_invoice("stripe", "in_123", "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :price_id}]}} =
               MishkaPay.change_subscription(%{change | price_id: "prod_123"})

      assert {:error, %Errors.Invalid{errors: [%{field: :item_id}]}} =
               MishkaPay.change_subscription(%{change | item_id: "sub_1"})

      params =
        Stripe.Mapper.change_params(
          struct!(
            MishkaPay.SubscriptionChange,
            Map.put(change, :proration_date, ~U[2026-11-16 00:00:00Z])
          ),
          "si_123"
        )

      assert params == %{
               "items" => [%{"id" => "si_123", "price" => "price_123", "quantity" => 2}],
               "proration_behavior" => "always_invoice",
               "proration_date" => 1_794_787_200,
               "billing_cycle_anchor" => %{"type" => "unchanged"},
               "payment_behavior" => "error_if_incomplete"
             }

      assert %{"subscription" => "sub_123", "subscription_details" => details} =
               Stripe.Mapper.preview_params(
                 struct!(MishkaPay.SubscriptionChange, change),
                 "si_123"
               )

      refute Map.has_key?(details, "payment_behavior")
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

    test "checkout options and discounts are sent as Stripe's spec accepts, and a checkout is ended" do
      options = %{
        discounts: [%{coupon_id: "SPRING"}],
        automatic_tax: true,
        customer_creation: :always,
        locale: "de",
        expires_at: DateTime.add(DateTime.utc_now(), 3600),
        billing_address: :required,
        tax_id_collection: true
      }

      assert {:ok, %Checkout{id: id, status: :open}} =
               MishkaPay.checkout(Map.merge(@checkout, options))

      assert {:ok, %Checkout{}} =
               MishkaPay.checkout(Map.put(@checkout, :allow_promotion_codes, true))

      assert {:ok, %Checkout{id: "cs_" <> _}} = MishkaPay.expire_checkout("stripe", id, "site-a")

      params = Stripe.Mapper.checkout_params(struct!(params_checkout(), options))

      assert %{
               "discounts" => [%{"coupon" => "SPRING"}],
               "automatic_tax" => %{"enabled" => true},
               "customer_creation" => "always",
               "locale" => "de",
               "billing_address_collection" => "required",
               "tax_id_collection" => %{"enabled" => true},
               "expires_at" => expires_at
             } = params

      assert expires_at == DateTime.to_unix(options.expires_at)

      refute Map.has_key?(
               Stripe.Mapper.checkout_params(params_checkout()),
               "allow_promotion_codes"
             )
    end

    test "coupons and promotion codes are made, read, listed and changed as Stripe's spec accepts" do
      assert {:ok, %MishkaPay.Coupon{id: coupon_id}} =
               MishkaPay.create_coupon(%{
                 provider: "stripe",
                 tenant: "site-a",
                 name: "Spring",
                 amount_off: %{amount: "5", currency: "USD"},
                 duration: :repeating,
                 duration_in_months: 3,
                 max_redemptions: 100
               })

      assert {:ok, %MishkaPay.Coupon{}} = MishkaPay.fetch_coupon("stripe", coupon_id, "site-a")

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.Coupon{} | _]}} =
               MishkaPay.list_coupons("stripe", "site-a")

      assert {:ok, %MishkaPay.PromotionCode{id: "promo_" <> _ = code_id}} =
               MishkaPay.create_promotion_code(%{
                 provider: "stripe",
                 tenant: "site-a",
                 coupon_id: coupon_id,
                 code: "SPRING5",
                 first_time_transaction: true,
                 minimum_amount: %{amount: "20", currency: "USD"}
               })

      assert {:ok, %MishkaPay.PromotionCode{}} =
               MishkaPay.fetch_promotion_code("stripe", code_id, "site-a")

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.PromotionCode{} | _]}} =
               MishkaPay.list_promotion_codes("stripe", "site-a", code: "SPRING5", active: true)

      assert {:ok, %MishkaPay.PromotionCode{}} =
               MishkaPay.update_promotion_code(%{
                 provider: "stripe",
                 tenant: "site-a",
                 id: code_id,
                 active: false
               })

      assert :ok = MishkaPay.delete_coupon("stripe", coupon_id, "site-a")
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

    test "an expiry out of Stripe's 30 minutes to 24 hours, or an id that is not plain, is refused" do
      for minutes <- [10, 25 * 60] do
        assert {:error, %Errors.Invalid{errors: [%{field: :expires_at}]}} =
                 MishkaPay.checkout(
                   Map.put(@checkout, :expires_at, DateTime.add(DateTime.utc_now(), minutes * 60))
                 )
      end

      assert {:error, %Errors.Invalid{errors: [%{field: :coupon_id}]}} =
               MishkaPay.fetch_coupon("stripe", "../charges")

      assert {:error, %Errors.Invalid{errors: [%{field: :id}]}} =
               MishkaPay.create_coupon(%{provider: "stripe", id: "a b", percent_off: 5})

      assert {:error, %Errors.Invalid{errors: [%{field: :promotion_code_id}]}} =
               MishkaPay.fetch_promotion_code("stripe", "cus_123")
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

  test "a customer maps with its reference and card on file, and a deleted one is a rejection" do
    assert {:ok, %MishkaPay.Customer{} = customer} =
             Stripe.Mapper.customer(%{
               "id" => "cus_1",
               "email" => "ava@example.com",
               "name" => "Ava",
               "phone" => "",
               "metadata" => %{"mishka_pay_reference" => "user-1", "plan" => "pro"},
               "invoice_settings" => %{"default_payment_method" => "pm_1"},
               "created" => 1_794_000_000
             })

    assert {customer.reference, customer.metadata, customer.default_payment_method,
            customer.phone} ==
             {"user-1", %{"plan" => "pro"}, "pm_1", nil}

    assert {:error, %Errors.Rejected{status: 404, code: "customer_deleted"}} =
             Stripe.Mapper.customer(%{"id" => "cus_2", "deleted" => true})
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

  test "a coupon and a promotion code map from Stripe's objects, the code's coupon from its promotion" do
    assert {:ok,
            %MishkaPay.Coupon{
              id: "Or6TT44r",
              duration: :once,
              valid: true,
              times_redeemed: 0,
              name: nil,
              amount_off: nil
            } = coupon} =
             Stripe.Mapper.coupon(%{
               "id" => "Or6TT44r",
               "object" => "coupon",
               "percent_off" => 10.0,
               "amount_off" => nil,
               "currency" => nil,
               "duration" => "once",
               "name" => "",
               "valid" => true,
               "times_redeemed" => 0,
               "created" => 1_794_825_000
             })

    assert Decimal.equal?(coupon.percent_off, Decimal.new(10))

    assert {:ok, %MishkaPay.Coupon{amount_off: amount}} =
             Stripe.Mapper.coupon(%{
               "id" => "five",
               "amount_off" => 500,
               "currency" => "usd",
               "duration" => "repeating",
               "duration_in_months" => 3,
               "valid" => false
             })

    assert Money.equal?(amount, Money.new(:USD, "5.00"))

    assert {:ok,
            %MishkaPay.PromotionCode{
              id: "promo_1",
              code: "SPRING5",
              coupon_id: "Or6TT44r",
              active: true,
              first_time_transaction: true,
              minimum_amount: minimum
            }} =
             Stripe.Mapper.promotion_code(%{
               "id" => "promo_1",
               "code" => "SPRING5",
               "active" => true,
               "promotion" => %{"type" => "coupon", "coupon" => "Or6TT44r"},
               "restrictions" => %{
                 "first_time_transaction" => true,
                 "minimum_amount" => 2000,
                 "minimum_amount_currency" => "usd"
               },
               "times_redeemed" => 0,
               "created" => 1_794_825_000
             })

    assert Money.equal?(minimum, Money.new(:USD, "20.00"))

    assert %{"promotion" => %{"type" => "coupon", "coupon" => "Or6TT44r"}} =
             Stripe.Mapper.promotion_code_params(%MishkaPay.PromotionCode{coupon_id: "Or6TT44r"})
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

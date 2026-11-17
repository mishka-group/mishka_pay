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

  @upload %{
    provider: "stripe",
    tenant: "site-a",
    purpose: :dispute_evidence,
    filename: "receipt.pdf",
    content_type: "application/pdf",
    content: "%PDF-1.4\nreceipt of order 9\n%%EOF\n"
  }

  @tax %{
    provider: "stripe",
    tenant: "site-a",
    items: [
      %{
        reference: "sku-1",
        amount: %{amount: "60.00", currency: "EUR"},
        quantity: 2,
        tax_code: "txcd_99999999"
      },
      %{reference: "sku-2", amount: %{amount: "10.00", currency: "EUR"}, tax_behavior: :inclusive}
    ],
    address: %{country: "nl", postal_code: "1012 AB"},
    address_source: :shipping,
    shipping: %{amount: "4.95", currency: "EUR"}
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

      for billing <- [%{}, %{billing_mode: :flexible, proration_discounts: :included}] do
        plan = %{@checkout | items: [%{id: "price_monthly"}]}

        assert {:ok, %Checkout{id: "cs_" <> _}} =
                 MishkaPay.checkout(Map.merge(plan, Map.put(billing, :mode, :subscription)))
      end
    end

    test "request options send another API version and expand objects, as Stripe's spec accepts" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        send(test, {:sent, conn.method, Map.new(conn.req_headers), conn.query_string})
        StripeMock.forward(conn)
      end)

      keys = %{secret_key: "sk_test_123"}

      options = %MishkaPay.RequestOptions{
        api_version: "2025-03-31.basil",
        expand: ["data.customer"]
      }

      assert {:ok, %{"object" => "list"}} =
               Stripe.request(:get, "/v1/payment_intents", [{"limit", "1"}], keys,
                 request_options: options
               )

      assert_received {:sent, "GET", %{"stripe-version" => "2025-03-31.basil"}, query}
      assert %{"expand[]" => "data.customer", "limit" => "1"} = URI.decode_query(query)

      assert {:ok, %{"object" => "customer"}} =
               Stripe.request(:post, "/v1/customers", %{"email" => "a@shop.test"}, keys,
                 request_options: %MishkaPay.RequestOptions{expand: ["invoice_settings"]}
               )

      assert_received {:sent, "POST", %{"stripe-version" => version}, ""}
      assert version == Stripe.version()
    end

    test "a raw call reads and writes any path with the site's key, one idempotency key per reference" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        send(test, {:sent, conn.method, conn.request_path, Map.new(conn.req_headers)})
        StripeMock.forward(conn)
      end)

      ref = :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :raw_request, :stop]])

      assert {:ok, %{"object" => "balance", "available" => [_ | _]}} =
               MishkaPay.request(%{provider: "stripe", tenant: "site-a", path: "/v1/balance"})

      assert_received {:sent, "GET", "/v1/balance", headers}
      assert headers["authorization"] == "Bearer sk_test_123"
      assert headers["stripe-version"] == Stripe.version()
      refute Map.has_key?(headers, "idempotency-key")

      assert_received {[:mishka_pay, :raw_request, :stop], ^ref, _,
                       %{provider: "stripe", tenant: "site-a", outcome: :ok}}

      write = %{
        provider: "stripe",
        tenant: "site-a",
        method: "post",
        path: "/v1/customers",
        params: %{"email" => "raw@shop.test", "metadata" => %{"plan" => "pro"}},
        reference: "raw-1",
        options: %{api_version: "2025-03-31.basil", expand: ["invoice_settings"]}
      }

      assert {:ok, %{"object" => "customer", "id" => "cus_" <> _}} = MishkaPay.request(write)
      assert_received {:sent, "POST", "/v1/customers", %{"idempotency-key" => key} = first}
      assert first["stripe-version"] == "2025-03-31.basil"

      assert {:ok, %{"object" => "customer"}} = MishkaPay.request(write)
      assert_received {:sent, "POST", "/v1/customers", %{"idempotency-key" => ^key}}

      assert {:ok, %{"deleted" => true}} =
               MishkaPay.request(%{
                 provider: "stripe",
                 method: :delete,
                 path: "/v1/customers/cus_1"
               })

      assert {:error, %Errors.Rejected{status: 404}} =
               MishkaPay.request(%{provider: "stripe", path: "/v1/no_such_thing"})
    end

    test "a site acting for a connected account sends it as Stripe-Account on every call; the platform sends none" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        send(test, {:sent, conn.request_path, Map.new(conn.req_headers)})
        StripeMock.forward(conn)
      end)

      MishkaPay.Test.put_keys(
        "stripe",
        %{secret_key: "sk_test_platform", account_id: "acct_site_b"},
        "site-b"
      )

      assert {:ok, %Payment{}} = MishkaPay.fetch_payment("stripe", "pi_123", "site-b")
      assert_received {:sent, "/v1/payment_intents/pi_123", read}

      assert {read["stripe-account"], read["authorization"]} ==
               {"acct_site_b", "Bearer sk_test_platform"}

      assert {:ok, %{"object" => "balance"}} =
               MishkaPay.request(%{provider: "stripe", tenant: "site-b", path: "/v1/balance"})

      assert_received {:sent, "/v1/balance", %{"stripe-account" => "acct_site_b"}}

      assert {:ok, %Checkout{}} = MishkaPay.checkout(%{@checkout | tenant: "site-b"})
      assert_received {:sent, "/v1/checkout/sessions", %{"stripe-account" => "acct_site_b"}}

      assert {:ok, %Payment{}} = MishkaPay.fetch_payment("stripe", "pi_123", "site-a")
      assert_received {:sent, "/v1/payment_intents/pi_123", platform}
      refute Map.has_key?(platform, "stripe-account")
    end

    test "connected accounts are made, read, changed, listed and turned down, and their links made, as Stripe's spec accepts" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        send(test, {:sent, conn.method, conn.request_path})
        StripeMock.forward(conn)
      end)

      account = %{
        provider: "stripe",
        tenant: "site-a",
        type: :express,
        country: "us",
        email: "Seller@Shop.test",
        business_name: "Ava's books",
        capabilities: ["card_payments", "transfers"],
        reference: "site-42"
      }

      assert {:ok,
              %MishkaPay.ConnectedAccount{
                id: "acct_" <> _,
                capability_status: %{"transfers" => :active},
                requirements_due: [_ | _]
              }} = MishkaPay.create_connected_account(account)

      assert_received {:sent, "POST", "/v1/accounts"}

      for type <- [:standard, :custom] do
        assert {:ok, %MishkaPay.ConnectedAccount{}} =
                 MishkaPay.create_connected_account(%{account | type: type})
      end

      assert {:ok, %MishkaPay.ConnectedAccount{id: "acct_123", charges_enabled: false}} =
               MishkaPay.fetch_connected_account("stripe", "acct_123", "site-a")

      assert {:ok, %MishkaPay.ConnectedAccount{}} =
               MishkaPay.update_connected_account(%{
                 provider: "stripe",
                 id: "acct_123",
                 email: "new@shop.test",
                 metadata: %{"plan" => "pro"}
               })

      assert_received {:sent, "POST", "/v1/accounts/acct_123"}

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.ConnectedAccount{} | _]}} =
               MishkaPay.list_connected_accounts("stripe", "site-a", limit: 3)

      assert {:ok, %MishkaPay.ConnectedAccount{}} =
               MishkaPay.reject_connected_account("stripe", "acct_123", "site-a",
                 reason: "terms_of_service"
               )

      assert_received {:sent, "POST", "/v1/accounts/acct_123/reject"}

      assert {:ok,
              %MishkaPay.AccountLink{
                type: :onboarding,
                account_id: "acct_123",
                url: "https://" <> _,
                expires_at: %DateTime{}
              }} =
               MishkaPay.account_link(%{
                 provider: "stripe",
                 tenant: "site-a",
                 account_id: "acct_123",
                 refresh_url: "https://shop.test/connect/again",
                 return_url: "https://shop.test/connect/done"
               })

      assert_received {:sent, "POST", "/v1/account_links"}

      assert {:ok, %MishkaPay.AccountLink{type: :login, url: "https://" <> _}} =
               MishkaPay.login_link("stripe", "acct_123", "site-a")

      assert_received {:sent, "POST", "/v1/accounts/acct_123/login_links"}
    end

    test "a connected account goes to Stripe as its controller, and one reference makes it once" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        key = Plug.Conn.get_req_header(conn, "idempotency-key")
        send(test, {:stripe, conn.request_path, URI.decode_query(body), key})

        Req.Test.json(conn, %{
          "object" => "account",
          "id" => "acct_9",
          "controller" => %{"stripe_dashboard" => %{"type" => "express"}},
          "metadata" => %{"mishka_pay_reference" => "site-42", "plan" => "pro"},
          "requirements" => %{"currently_due" => ["external_account"], "disabled_reason" => nil}
        })
      end)

      account = %{
        provider: "stripe",
        tenant: "site-a",
        country: "de",
        email: "seller@shop.test",
        capabilities: ["transfers"],
        reference: "site-42",
        metadata: %{"plan" => "pro"}
      }

      assert {:ok,
              %MishkaPay.ConnectedAccount{
                id: "acct_9",
                type: :express,
                reference: "site-42",
                metadata: %{"plan" => "pro"},
                requirements_due: ["external_account"]
              }} = MishkaPay.create_connected_account(account)

      assert {:ok, _again} = MishkaPay.create_connected_account(account)

      assert_received {:stripe, "/v1/accounts", params, [key]}
      assert_received {:stripe, "/v1/accounts", ^params, [^key]}

      assert params == %{
               "controller[stripe_dashboard][type]" => "express",
               "controller[fees][payer]" => "application",
               "controller[losses][payments]" => "application",
               "country" => "DE",
               "email" => "seller@shop.test",
               "capabilities[transfers][requested]" => "true",
               "metadata[mishka_pay_reference]" => "site-42",
               "metadata[plan]" => "pro"
             }

      assert {:ok, _changed} =
               MishkaPay.update_connected_account(%{
                 provider: "stripe",
                 id: "acct_9",
                 business_name: "Ava's books"
               })

      assert_received {:stripe, "/v1/accounts/acct_9",
                       %{"business_profile[name]" => "Ava's books"} = only, _key}

      assert map_size(only) == 1
    end

    test "transfers, payouts and application fees are sent, read, listed and given back, as Stripe's spec accepts" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        send(test, {:sent, conn.method, conn.request_path, conn.query_string})
        StripeMock.forward(conn)
      end)

      assert {:ok,
              %MishkaPay.Transfer{id: "tr_" <> _, amount: %Money{}, destination: "acct_" <> _}} =
               MishkaPay.create_transfer(%{
                 provider: "stripe",
                 tenant: "site-a",
                 amount: %{amount: "11.00", currency: "USD"},
                 destination: "acct_123",
                 transfer_group: "order-7",
                 reference: "payout-order-7"
               })

      assert {:ok, %MishkaPay.Transfer{id: "tr_123"}} =
               MishkaPay.fetch_transfer("stripe", "tr_123", "site-a")

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.Transfer{} | _]}} =
               MishkaPay.list_transfers("stripe", "site-a",
                 destination: "acct_123",
                 transfer_group: "order-7"
               )

      assert_received {:sent, "GET", "/v1/transfers", query}

      assert %{"destination" => "acct_123", "transfer_group" => "order-7"} =
               URI.decode_query(query)

      assert {:ok, %MishkaPay.Transfer{id: "tr_" <> _}} =
               MishkaPay.reverse_transfer("stripe", "tr_123", "site-a",
                 amount: %{amount: "1.00", currency: "USD"},
                 reference: "undo-1"
               )

      assert_received {:sent, "POST", "/v1/transfers/tr_123/reversals", _}

      assert {:ok, %MishkaPay.Payout{id: "po_123", status: :in_transit, automatic: true}} =
               MishkaPay.fetch_payout("stripe", "po_123", "site-a")

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.Payout{} | _]}} =
               MishkaPay.list_payouts("stripe", "site-a", status: :in_transit)

      assert_received {:sent, "GET", "/v1/payouts", payouts}
      assert %{"status" => "in_transit"} = URI.decode_query(payouts)

      assert {:ok, %MishkaPay.Payout{}} = MishkaPay.cancel_payout("stripe", "po_123", "site-a")
      assert_received {:sent, "POST", "/v1/payouts/po_123/cancel", _}

      assert {:ok, %MishkaPay.ApplicationFee{id: "fee_123", account_id: "acct_" <> _}} =
               MishkaPay.fetch_application_fee("stripe", "fee_123", "site-a")

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.ApplicationFee{charge_id: "ch_" <> _} | _]}} =
               MishkaPay.list_application_fees("stripe", "site-a", charge_id: "ch_1")

      assert {:ok, %MishkaPay.ApplicationFee{id: "fee_" <> _}} =
               MishkaPay.refund_application_fee("stripe", "fee_123", "site-a")

      assert_received {:sent, "POST", "/v1/application_fees/fee_123/refunds", _}
    end

    test "a checkout for a seller sends its fee and destination where Stripe takes them" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:stripe, conn.request_path, Plug.Conn.Query.decode(body)})

        Req.Test.json(conn, %{
          "object" => "checkout.session",
          "id" => "cs_1",
          "url" => "https://checkout.stripe.com/c/pay/cs_1",
          "status" => "open"
        })
      end)

      seller = %{destination: "acct_seller", on_behalf_of: "acct_seller"}

      assert {:ok, %Checkout{}} =
               @checkout
               |> Map.merge(seller)
               |> Map.put(:application_fee, %{amount: "2.50", currency: "USD"})
               |> MishkaPay.checkout()

      assert_received {:stripe, "/v1/checkout/sessions", %{"payment_intent_data" => intent}}

      assert %{
               "application_fee_amount" => "250",
               "transfer_data" => %{"destination" => "acct_seller"},
               "on_behalf_of" => "acct_seller"
             } = intent

      plan = %{
        @checkout
        | items: [
            %{
              name: "Pro",
              amount: %{amount: "10.00", currency: "USD"},
              interval: :month
            }
          ]
      }

      assert {:ok, %Checkout{}} =
               plan
               |> Map.merge(seller)
               |> Map.merge(%{mode: :subscription, application_fee_percent: "12.5"})
               |> MishkaPay.checkout()

      assert_received {:stripe, "/v1/checkout/sessions", %{"subscription_data" => subscription}}

      assert %{
               "application_fee_percent" => "12.5",
               "transfer_data" => %{"destination" => "acct_seller"},
               "on_behalf_of" => "acct_seller"
             } = subscription
    end

    test "a transfer, a reversal and a fee refund are each made once per reference" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [key] = Plug.Conn.get_req_header(conn, "idempotency-key")
        send(test, {:stripe, conn.request_path, URI.decode_query(body), key})
        Req.Test.json(conn, answer_for(conn.request_path))
      end)

      transfer = %{
        provider: "stripe",
        tenant: "site-a",
        amount: %{amount: "11.00", currency: "EUR"},
        destination: "acct_1",
        source_charge_id: "ch_1",
        reference: "order-7"
      }

      for _twice <- 1..2,
          do: assert({:ok, %MishkaPay.Transfer{}} = MishkaPay.create_transfer(transfer))

      assert_received {:stripe, "/v1/transfers", params, key}
      assert_received {:stripe, "/v1/transfers", ^params, ^key}

      assert params == %{
               "amount" => "1100",
               "currency" => "eur",
               "destination" => "acct_1",
               "source_transaction" => "ch_1",
               "metadata[mishka_pay_reference]" => "order-7"
             }

      assert {:ok, %MishkaPay.Transfer{amount_reversed: reversed}} =
               MishkaPay.reverse_transfer("stripe", "tr_1", "site-a", reference: "undo-7")

      assert Money.equal?(reversed, Money.new(:EUR, "11.00"))

      assert_received {:stripe, "/v1/transfers/tr_1/reversals", %{"expand[]" => "transfer"} = all,
                       undo}

      refute Map.has_key?(all, "amount")

      # The same reference on another transfer is another reversal.
      MishkaPay.reverse_transfer("stripe", "tr_2", "site-a", reference: "undo-7")
      assert_received {:stripe, "/v1/transfers/tr_2/reversals", _all, other}
      refute other == undo

      assert {:ok, %MishkaPay.ApplicationFee{refunded: false}} =
               MishkaPay.refund_application_fee("stripe", "fee_1", "site-a",
                 amount: %{amount: "0.50", currency: "EUR"}
               )

      assert_received {:stripe, "/v1/application_fees/fee_1/refunds",
                       %{"amount" => "50", "expand[]" => "fee"}, _}
    end

    test "a platform that has not signed up for Connect is told so plainly" do
      MishkaPay.Test.stub_http(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => %{
            "type" => "invalid_request_error",
            "message" =>
              "You can only create new accounts if you've signed up for Connect, which you can do at https://dashboard.stripe.com/connect."
          }
        })
      end)

      assert {:error, %Errors.Rejected{code: "connect_not_set_up"} = error} =
               MishkaPay.create_connected_account(%{provider: "stripe", country: "US"})

      assert Exception.message(error) =~ "signed up for Connect"
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

      assert {:error, %Errors.Rejected{param: "trial_days"} = error} =
               MishkaPay.create_payment_link(%{
                 provider: "stripe",
                 items: [%{id: "price_1"}],
                 trial_days: 7
               })

      assert Exception.message(error) ==
               "Stripe did not accept the value given for trial_days: check it and try again"
    end

    test "Stripe's should-retry false and rate-limit reason: one request, the reason kept, plain words" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        send(test, :asked)

        conn
        |> Plug.Conn.put_resp_header("stripe-should-retry", "false")
        |> Plug.Conn.put_resp_header("stripe-rate-limited-reason", "endpoint-concurrency")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{
          "error" => %{"type" => "invalid_request_error", "code" => "rate_limit"}
        })
      end)

      assert {:error,
              %Errors.Rejected{status: 429, rate_limit_reason: "endpoint-concurrency"} = error} =
               MishkaPay.fetch_payment("stripe", "pi_1", "site-a")

      assert_received :asked
      refute_received :asked
      assert Exception.message(error) =~ "Stripe is limiting how fast this site may ask"
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

      assert MishkaPay.Ash.message(taken) == "Stripe already has one with that code or id"

      assert {:error, %Errors.Rejected{code: "resource_missing"} = missing} =
               MishkaPay.checkout(Map.put(@checkout, :discounts, [%{coupon_id: "NOPE"}]))

      assert Exception.message(missing) == "Stripe has nothing with the id given"
    end

    test "a link Stripe refuses for a missing tax code or a one-time-only choice says which, plainly" do
      answers = %{
        "tax" =>
          "Invalid line_items[0]: the product tax code is missing. Set the product's tax_code field to an eligible product tax code.",
        "invoice" =>
          "`invoice_creation` can only be used if the payment link does not contain any recurring prices.",
        "trial" =>
          "You must pass a recurring price in `line_items` to specify `subscription_data`."
      }

      MishkaPay.Test.stub_http(fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        {message, param} =
          cond do
            params["invoice_creation[enabled]"] ->
              {answers["invoice"], nil}

            params["subscription_data[trial_period_days]"] ->
              {answers["trial"], "subscription_data"}

            true ->
              {answers["tax"], nil}
          end

        error = %{"type" => "invalid_request_error", "message" => message, "param" => param}
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => error})
      end)

      link = %{provider: "stripe", items: [%{id: "price_1", quantity: 1}]}

      assert {:error, %Errors.Rejected{code: "tax_code_missing", param: "tax_code"} = tax} =
               MishkaPay.create_payment_link(link)

      assert Exception.message(tax) =~ "give the product one, or turn merchant of record off"

      assert {:error, %Errors.Rejected{code: "one_time_only", param: "invoice"} = invoice} =
               MishkaPay.create_payment_link(Map.put(link, :invoice, true))

      assert Exception.message(invoice) =~ "invoice goes only with one-time prices"

      assert {:error, %Errors.Rejected{code: "recurring_only", param: "trial_days"} = trial} =
               MishkaPay.create_payment_link(Map.put(link, :trial_days, 7))

      assert Exception.message(trial) ==
               "trial_days goes only with a plan, a price charged on a schedule"
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

    test "a customer is deleted as Stripe's spec accepts, and an id of another kind never reaches a path" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :request, :start]])

      assert :ok = MishkaPay.delete_customer("stripe", "cus_123", "site-a")
      assert_received {_, ^ref, _, %{method: :delete, path: "/v1/customers/cus_123"}}

      for id <- ["pi_123", "cus_1/../../v1/charges"] do
        assert {:error, %Errors.Invalid{errors: [%{field: :customer_id}]}} =
                 MishkaPay.delete_customer("stripe", id, "site-a")
      end

      refute_received {_, ^ref, _, _meta}
    end

    test "a customer's tax ids are added, listed and removed as Stripe's spec accepts" do
      assert {:ok, %MishkaPay.TaxId{provider: "stripe", id: "txi_" <> _, type: type}} =
               MishkaPay.create_tax_id(
                 "stripe",
                 "cus_123",
                 %{"type" => " EU_VAT ", "value" => "DE123456789"},
                 "site-a"
               )

      assert type == "eu_vat"

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.TaxId{id: "txi_" <> _} | _]}} =
               MishkaPay.list_tax_ids("stripe", "cus_123", "site-a", limit: 3)

      assert :ok = MishkaPay.delete_tax_id("stripe", "cus_123", "txi_123", "site-a")
    end

    test "shipping rates are made and listed, and a checkout ships with them as Stripe's spec accepts" do
      assert {:ok, %MishkaPay.ShippingRate{id: "shr_" <> _}} =
               MishkaPay.create_shipping_rate(%{
                 provider: "stripe",
                 tenant: "site-a",
                 name: "Express",
                 amount: %{amount: "9.90", currency: "USD"},
                 min_days: 1,
                 max_days: 2,
                 tax_code: "txcd_92010001",
                 tax_behavior: :exclusive
               })

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.ShippingRate{} | _]}} =
               MishkaPay.list_shipping_rates("stripe", "site-a", active: true, limit: 3)

      checkout =
        Map.merge(@checkout, %{
          merchant_of_record: false,
          shipping_countries: ["nl", "DE"],
          shipping_rates: [
            "shr_123",
            %{name: "Post", amount: %{amount: "4.95", currency: "USD"}, min_days: 2, max_days: 5}
          ]
        })

      assert {:ok, %Checkout{id: "cs_" <> _}} = MishkaPay.checkout(checkout)

      assert %{
               "shipping_address_collection" => %{"allowed_countries" => ["NL", "DE"]},
               "shipping_options" => [
                 %{"shipping_rate" => "shr_123"},
                 %{
                   "shipping_rate_data" => %{
                     "display_name" => "Post",
                     "type" => "fixed_amount",
                     "fixed_amount" => %{"amount" => 495, "currency" => "usd"},
                     "delivery_estimate" => %{
                       "minimum" => %{"unit" => "business_day", "value" => 2},
                       "maximum" => %{"unit" => "business_day", "value" => 5}
                     }
                   }
                 }
               ]
             } = Stripe.Mapper.checkout_params(elem(Checkout.builder(checkout), 1))

      subscription =
        Map.merge(@checkout, %{
          mode: :subscription,
          items: [%{name: "Box", amount: %{amount: "20", currency: "USD"}, interval: :month}],
          shipping_countries: ["NL"]
        })

      assert {:ok, %Checkout{mode: :subscription}} = MishkaPay.checkout(subscription)
    end

    test "shipping that cannot be right is refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
      post = %{name: "Post", amount: %{amount: "4.95", currency: "USD"}}

      for {changes, field} <- [
            {%{shipping_countries: ["NLD"]}, :shipping_countries},
            {%{shipping_countries: []}, :shipping_countries},
            {%{shipping_rates: [%{name: "Post"}]}, :shipping_rates},
            {%{shipping_rates: [%{post | amount: %{amount: "4.95", currency: "EUR"}}]}, :items},
            {%{shipping_rates: ["price_123"]}, :shipping_rates},
            {%{shipping_rates: List.duplicate(post, 6)}, :shipping_rates},
            {%{shipping_rates: [post], merchant_of_record: true}, :merchant_of_record},
            {%{shipping_rates: [post], mode: :subscription}, :shipping_rates}
          ] do
        assert {:error, %Errors.Invalid{errors: errors}} =
                 MishkaPay.checkout(Map.merge(@checkout, changes))

        assert Enum.any?(errors, &(&1.field == field)), inspect({changes, errors})
      end

      for {attrs, field} <- [
            {%{name: "Post"}, :amount},
            {Map.merge(post, %{min_days: 5, max_days: 2}), :max_days},
            {%{post | amount: %{amount: "4.955", currency: "USD"}}, :amount}
          ] do
        assert {:error, %Errors.Invalid{errors: errors}} =
                 MishkaPay.create_shipping_rate(Map.put(attrs, :provider, "stripe"))

        assert Enum.any?(errors, &(&1.field == field)), inspect({attrs, errors})
      end
    end

    test "shipping asked where Stripe sells as merchant of record is a plain rejection" do
      MishkaPay.Test.stub_http(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => %{
            "type" => "invalid_request_error",
            "message" =>
              "Unsupported parameter: shipping_options. Shipping parameters cannot be used with Managed Payments, which is enabled by default on your account."
          }
        })
      end)

      assert {:error, %Errors.Rejected{code: "managed_payments_shipping"} = error} =
               MishkaPay.checkout(Map.put(@checkout, :shipping_rates, ["shr_123"]))

      assert Exception.message(error) =~ "merchant of record does not ship"
    end

    test "the tax on a sale is counted and recorded as Stripe's spec accepts" do
      assert {:ok, %MishkaPay.TaxCalculation{id: "taxcalc_" <> _, amount_total: %Money{}}} =
               MishkaPay.calculate_tax(@tax)

      by_customer = @tax |> Map.delete(:address) |> Map.put(:customer_id, "cus_123")
      assert {:ok, %MishkaPay.TaxCalculation{}} = MishkaPay.calculate_tax(by_customer)

      assert {:ok, %MishkaPay.TaxTransaction{id: "tax_" <> _, calculation_id: "taxcalc_123"}} =
               MishkaPay.record_tax("stripe", "taxcalc_123", "order-7", "site-a")

      {:ok, calculation} = MishkaPay.TaxCalculation.builder(@tax)

      assert %{
               "currency" => "eur",
               "line_items" => [
                 %{"reference" => "sku-1", "amount" => 6000, "quantity" => 2},
                 %{"reference" => "sku-2", "amount" => 1000, "tax_behavior" => "inclusive"}
               ],
               "customer_details" => %{
                 "address" => %{"country" => "NL", "postal_code" => "1012 AB"},
                 "address_source" => "shipping"
               },
               "shipping_cost" => %{"amount" => 495},
               "expand" => ["line_items"]
             } = Stripe.Mapper.tax_calculation_params(calculation)
    end

    test "a tax record sends one idempotency key per reference" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        send(test, {:key, Plug.Conn.get_req_header(conn, "idempotency-key")})
        StripeMock.forward(conn)
      end)

      {:ok, _first} = MishkaPay.record_tax("stripe", "taxcalc_1", "order-7", "site-a")
      {:ok, _again} = MishkaPay.record_tax("stripe", "taxcalc_1", "order-7", "site-a")
      {:ok, _other} = MishkaPay.record_tax("stripe", "taxcalc_1", "order-8", "site-a")

      assert_receive {:key, [first]}
      assert_receive {:key, [^first]}
      assert_receive {:key, [other]}
      assert other != first
    end

    test "an account without Stripe Tax, or an address it cannot use, is a plain rejection" do
      for {code, ours} <- [
            {"stripe_tax_inactive", "tax_not_set_up"},
            {"customer_tax_location_invalid", "tax_location_invalid"}
          ] do
        MishkaPay.Test.stub_http(fn conn ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{
            "error" => %{
              "type" => "invalid_request_error",
              "code" => code,
              "message" => "Stripe's own words, with a dashboard link acct_123."
            }
          })
        end)

        assert {:error, %Errors.Rejected{status: 400, code: ^ours} = error} =
                 MishkaPay.calculate_tax(@tax)

        refute Exception.message(error) =~ "acct_"
      end
    end

    test "a tax calculation that cannot be right is refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
      [line, other] = @tax.items

      for {attrs, field} <- [
            {%{@tax | items: []}, :items},
            {%{@tax | items: [line, %{other | reference: "sku-1"}]}, :items},
            {%{@tax | items: [line, %{other | amount: %{amount: "10", currency: "USD"}}]},
             :items},
            {%{@tax | shipping: %{amount: "4.95", currency: "USD"}}, :items},
            {Map.delete(@tax, :address), :address},
            {%{@tax | address: %{country: "Netherlands"}}, :address},
            {%{@tax | items: [Map.delete(line, :reference)]}, :items},
            {@tax |> Map.delete(:address) |> Map.put(:customer_id, "sub_1"), :customer_id}
          ] do
        assert {:error, %Errors.Invalid{errors: errors}} = MishkaPay.calculate_tax(attrs)
        assert Enum.any?(errors, &(&1.field == field)), inspect({attrs, errors})
      end

      assert {:error, %Errors.Invalid{errors: [%{field: :calculation_id}]}} =
               MishkaPay.record_tax("stripe", "tax_1", "order-1")

      assert {:error, %Errors.Invalid{errors: [%{field: :reference}]}} =
               MishkaPay.record_tax("stripe", "taxcalc_1", "  ")
    end

    test "a tax id that cannot be right is refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
      vat = %{type: "eu_vat", value: "DE123456789"}

      for {call, field} <- [
            {fn -> MishkaPay.create_tax_id("stripe", "cus_1", %{vat | type: "eu vat"}) end,
             :type},
            {fn -> MishkaPay.create_tax_id("stripe", "cus_1", %{type: "eu_vat"}) end, :value},
            {fn -> MishkaPay.create_tax_id("stripe", "pi_1", vat) end, :customer_id},
            {fn -> MishkaPay.list_tax_ids("stripe", "cus_1/../x") end, :customer_id},
            {fn -> MishkaPay.delete_tax_id("stripe", "cus_1", "cus_2") end, :tax_id_id}
          ] do
        assert {:error, %Errors.Invalid{errors: errors}} = call.()
        assert Enum.any?(errors, &(&1.field == field)), inspect({field, errors})
      end
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

      assert params["subscription_data"]["billing_mode"] == %{
               "type" => "flexible",
               "flexible" => %{"proration_discounts" => "itemized"}
             }

      refute Map.has_key?(params, "payment_intent_data")

      assert [%{"price_data" => %{"recurring" => %{"interval" => "year", "interval_count" => 1}}}] =
               params["line_items"]
    end

    test "a subscription's billing mode is its own, else the tenant's, else flexible and itemized" do
      plan = %Checkout{
        provider: "stripe",
        mode: :subscription,
        items: [%MishkaPay.Price{id: "price_1", quantity: 1}],
        success_url: "https://shop.test/ok",
        cancel_url: "https://shop.test/no"
      }

      schedule = %MishkaPay.SubscriptionSchedule{
        provider: "stripe",
        customer_id: "cus_1",
        phases: [%MishkaPay.SubscriptionPhase{items: [%MishkaPay.Price{id: "price_1"}]}]
      }

      billing = fn choice, settings ->
        checkout = Stripe.Mapper.checkout_params(Map.merge(plan, choice), settings)
        made = Stripe.Mapper.subscription_schedule_params(Map.merge(schedule, choice), settings)
        assert checkout["subscription_data"]["billing_mode"] == made["billing_mode"]
        made["billing_mode"]
      end

      flexible = &%{"type" => "flexible", "flexible" => %{"proration_discounts" => &1}}

      assert billing.(%{}, %{}) == flexible.("itemized")
      assert billing.(%{billing_mode: :classic}, %{}) == %{"type" => "classic"}
      assert billing.(%{proration_discounts: :included}, %{}) == flexible.("included")

      assert billing.(%{}, %{billing_mode: :classic, proration_discounts: :included}) ==
               %{"type" => "classic"}

      assert billing.(%{}, %{proration_discounts: :included}) == flexible.("included")

      assert billing.(%{billing_mode: :flexible}, %{billing_mode: :classic}) ==
               flexible.("itemized")

      refute Map.has_key?(
               Stripe.Mapper.subscription_schedule_params(%{schedule | subscription_id: "sub_1"}),
               "billing_mode"
             )

      # Proration discounts asked of a tenant whose subscriptions are classic: no request.
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
      MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_123", billing_mode: :classic})

      for made <- [
            MishkaPay.checkout(%{
              provider: "stripe",
              mode: :subscription,
              items: [%{id: "price_1"}],
              success_url: "https://shop.test/ok",
              cancel_url: "https://shop.test/no",
              proration_discounts: :itemized
            }),
            MishkaPay.create_subscription_schedule(%{
              provider: "stripe",
              customer_id: "cus_1",
              phases: [%{items: [%{id: "price_1"}]}],
              proration_discounts: :itemized
            })
          ] do
        assert {:error, %Errors.Invalid{errors: [%{field: :proration_discounts}]}} = made
      end
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

    test "subscriptions are listed by customer, price and status, and searched, as Stripe's spec accepts" do
      test_pid = self()

      MishkaPay.Test.stub_http(fn conn ->
        send(test_pid, {:query, conn.request_path, URI.decode_query(conn.query_string)})
        StripeMock.forward(conn)
      end)

      assert {:ok, %MishkaPay.Page{items: [%Subscription{id: "sub_" <> _} | _]}} =
               MishkaPay.list_subscriptions("stripe", "site-a",
                 customer_id: "cus_123",
                 price_id: "price_123",
                 status: :all,
                 limit: 3,
                 after: "sub_0"
               )

      assert_received {:query, "/v1/subscriptions", query}

      assert %{
               "customer" => "cus_123",
               "price" => "price_123",
               "status" => "all",
               "limit" => "3",
               "starting_after" => "sub_0"
             } = query

      assert {:ok, %MishkaPay.Page{items: [%Subscription{} | _]}} =
               MishkaPay.search_subscriptions("stripe", "site-a",
                 status: :past_due,
                 reference: "order's-1",
                 metadata: %{"plan" => "pro"}
               )

      assert_received {:query, "/v1/subscriptions/search", %{"query" => search}}

      assert search ==
               ~S(status:'past_due' AND metadata['mishka_pay_reference']:'order\'s-1' AND metadata['plan']:'pro')
    end

    test "a subscription list or search that cannot be right is refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)

      for {opts, field} <- [
            {[customer_id: "sub_1"], :customer_id},
            {[price_id: "prod_1"], :price_id},
            {[status: :ended], :status},
            {[status: "active"], :status}
          ] do
        assert {:error, %Errors.Invalid{errors: [%{field: ^field}]}} =
                 MishkaPay.list_subscriptions("stripe", "site-a", opts)
      end

      assert {:error, %Errors.Invalid{errors: [%{field: :status, message: message}]}} =
               MishkaPay.search_subscriptions("stripe", "site-a", status: :all)

      assert message =~ "past_due"

      assert {:error, %Errors.Invalid{errors: [%{field: :query}]}} =
               MishkaPay.search_subscriptions("stripe", "site-a", limit: 5)
    end

    test "disputes are read, listed, answered with evidence and accepted as Stripe's spec accepts" do
      assert {:ok, %MishkaPay.Dispute{id: "dp_" <> _}} =
               MishkaPay.fetch_dispute("stripe", "dp_123", "site-a")

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.Dispute{} | _]}} =
               MishkaPay.list_disputes("stripe", "site-a", payment_id: "pi_123")

      assert {:ok, %MishkaPay.Dispute{}} =
               MishkaPay.update_dispute(%{
                 provider: "stripe",
                 tenant: "site-a",
                 dispute_id: "dp_123",
                 evidence: %{"uncategorized_text" => "The buyer downloaded the ebook twice."},
                 submit: false
               })

      assert {:ok, %MishkaPay.Dispute{}} = MishkaPay.accept_dispute("stripe", "dp_123", "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :dispute_id}]}} =
               MishkaPay.fetch_dispute("stripe", "pi_123")
    end

    test "a file is uploaded as multipart, read, linked and put in a dispute's evidence, as Stripe's spec accepts" do
      assert {:ok, %MishkaPay.File{id: "file_" <> _ = id, purpose: :dispute_evidence} = file} =
               MishkaPay.upload_file(@upload)

      assert is_integer(file.size)
      assert %DateTime{} = file.created_at

      assert {:ok, %MishkaPay.File{id: "file_" <> _}} =
               MishkaPay.fetch_file("stripe", "file_123", "site-a")

      at = DateTime.add(DateTime.utc_now(), 3600)

      assert {:ok, %MishkaPay.FileLink{id: "link_" <> _, url: "https://" <> _, expired: false}} =
               MishkaPay.file_link("stripe", id, "site-a", expires_at: at)

      assert {:ok, %MishkaPay.Dispute{}} =
               MishkaPay.update_dispute(%{
                 provider: "stripe",
                 tenant: "site-a",
                 dispute_id: "dp_123",
                 evidence: %{"uncategorized_file" => id, "receipt" => "file_456"},
                 submit: false
               })
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

    test "a one-off bill goes to Stripe as a draft and its items, as Stripe's spec accepts" do
      draft = %{
        provider: "stripe",
        tenant: "site-a",
        customer_id: "cus_123",
        collection: :send_invoice,
        reference: "order-9",
        items: [
          %{name: "Setup", amount: %{amount: "120", currency: "USD"}, quantity: 2},
          %{id: "price_123"}
        ]
      }

      assert {:ok, %Invoice{id: "in_" <> _}} = MishkaPay.create_invoice(draft)

      for call <- [
            &MishkaPay.finalize_invoice/3,
            &MishkaPay.send_invoice/3,
            &MishkaPay.void_invoice/3,
            &MishkaPay.mark_invoice_uncollectible/3
          ] do
        assert {:ok, %Invoice{}} = call.("stripe", "in_123", "site-a")
      end

      assert {:ok, %Invoice{}} =
               MishkaPay.pay_invoice("stripe", "in_123", "site-a", out_of_band: true)

      assert :ok = MishkaPay.delete_invoice("stripe", "in_123", "site-a")
    end

    test "invoice items are added, changed, listed and removed as Stripe's spec accepts" do
      assert {:ok, %MishkaPay.InvoiceItem{id: "ii_" <> _, provider: "stripe"}} =
               MishkaPay.create_invoice_item(%{
                 provider: "stripe",
                 tenant: "site-a",
                 customer_id: "cus_123",
                 name: "Setup fee",
                 amount: %{amount: "49.00", currency: "USD"},
                 quantity: 2,
                 tax_behavior: :exclusive,
                 reference: "setup-1",
                 metadata: %{"team" => "ops"}
               })

      assert {:ok, %MishkaPay.InvoiceItem{}} =
               MishkaPay.create_invoice_item(%{
                 provider: "stripe",
                 tenant: "site-a",
                 customer_id: "cus_123",
                 invoice_id: "in_123",
                 price_id: "price_123"
               })

      assert {:ok, %MishkaPay.InvoiceItem{}} =
               MishkaPay.update_invoice_item(%{
                 provider: "stripe",
                 tenant: "site-a",
                 id: "ii_123",
                 name: "Setup fee, two hours",
                 amount: %{amount: "60", currency: "USD"},
                 quantity: 3
               })

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.InvoiceItem{} | _]}} =
               MishkaPay.list_invoice_items("stripe", "site-a",
                 customer_id: "cus_123",
                 pending: true,
                 limit: 3
               )

      assert {:ok, %MishkaPay.Page{}} =
               MishkaPay.list_invoice_items("stripe", "site-a", invoice_id: "in_123")

      assert :ok = MishkaPay.delete_invoice_item("stripe", "ii_123", "site-a")
    end

    test "an invoice item goes to Stripe as a draft's item does, keyed by its reference" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        key = Plug.Conn.get_req_header(conn, "idempotency-key")
        send(test, {:stripe, conn.method, conn.request_path, URI.decode_query(body), key})
        Req.Test.json(conn, %{"object" => "invoiceitem", "id" => "ii_1", "currency" => "usd"})
      end)

      item = %{
        provider: "stripe",
        tenant: "site-a",
        customer_id: "cus_123",
        name: "Late fee",
        amount: %{amount: "12.50", currency: "EUR"},
        tax_code: "txcd_20030000",
        reference: "late-7"
      }

      {:ok, _item} = MishkaPay.create_invoice_item(item)
      {:ok, _again} = MishkaPay.create_invoice_item(item)

      assert_received {:stripe, "POST", "/v1/invoiceitems", params, [key]}

      assert params == %{
               "customer" => "cus_123",
               "description" => "Late fee",
               "currency" => "eur",
               "unit_amount_decimal" => "1250",
               "tax_code" => "txcd_20030000",
               "metadata[mishka_pay_reference]" => "late-7"
             }

      assert_received {:stripe, "POST", "/v1/invoiceitems", _params, [^key]}

      {:ok, _changed} =
        MishkaPay.update_invoice_item(%{provider: "stripe", id: "ii_1", quantity: 4})

      assert_received {:stripe, "POST", "/v1/invoiceitems/ii_1", %{"quantity" => "4"} = change,
                       _key}

      assert map_size(change) == 1
    end

    test "subscription schedules are made, read, listed, changed, released and canceled as Stripe's spec accepts" do
      assert {:ok, %MishkaPay.SubscriptionSchedule{id: "sub_sched_" <> _ = id, phases: [_ | _]}} =
               MishkaPay.create_subscription_schedule(%{
                 provider: "stripe",
                 tenant: "site-a",
                 customer_id: "cus_123",
                 end_behavior: :cancel,
                 reference: "member-1",
                 phases: [
                   %{
                     items: [%{id: "price_intro", quantity: 2}],
                     iterations: 3,
                     interval: :month,
                     trial: true
                   },
                   %{
                     items: [%{id: "price_full"}],
                     end_at: ~U[2027-06-01 00:00:00Z],
                     proration: :none
                   }
                 ]
               })

      assert {:ok, %MishkaPay.SubscriptionSchedule{}} =
               MishkaPay.create_subscription_schedule(%{
                 provider: "stripe",
                 subscription_id: "sub_123"
               })

      assert {:ok, %MishkaPay.SubscriptionSchedule{id: ^id}} =
               MishkaPay.fetch_subscription_schedule("stripe", id, "site-a")

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.SubscriptionSchedule{} | _]}} =
               MishkaPay.list_subscription_schedules("stripe", "site-a",
                 customer_id: "cus_123",
                 scheduled: true,
                 limit: 3
               )

      assert {:ok, %MishkaPay.SubscriptionSchedule{}} =
               MishkaPay.update_subscription_schedule(%{
                 provider: "stripe",
                 id: id,
                 end_behavior: :release,
                 proration: :always_invoice,
                 phases: [
                   %{
                     items: [%{id: "price_intro"}],
                     start_at: ~U[2026-11-01 00:00:00Z],
                     end_at: ~U[2027-01-01 00:00:00Z]
                   },
                   %{items: [%{id: "price_full"}], iterations: 2, interval: :year}
                 ]
               })

      assert {:ok, %MishkaPay.SubscriptionSchedule{}} =
               MishkaPay.release_subscription_schedule("stripe", id, "site-a")

      assert {:ok, %MishkaPay.SubscriptionSchedule{}} =
               MishkaPay.cancel_subscription_schedule("stripe", id, "site-a",
                 invoice_now: true,
                 prorate: false
               )
    end

    test "a schedule goes to Stripe with each phase's duration, keyed by its reference" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        key = Plug.Conn.get_req_header(conn, "idempotency-key")
        send(test, {:stripe, conn.method, conn.request_path, Plug.Conn.Query.decode(body), key})

        Req.Test.json(conn, %{
          "object" => "subscription_schedule",
          "id" => "sub_sched_1",
          "status" => "not_started",
          "phases" => []
        })
      end)

      schedule = %{
        provider: "stripe",
        tenant: "site-a",
        customer_id: "cus_1",
        start_at: ~U[2026-12-01 00:00:00Z],
        end_behavior: "cancel",
        reference: "member-7",
        phases: [
          %{items: [%{id: "price_intro"}], iterations: 3, interval: "month", trial: true},
          %{items: [%{id: "price_full", quantity: 2}], end_at: ~U[2027-12-01 00:00:00Z]}
        ]
      }

      {:ok, _schedule} = MishkaPay.create_subscription_schedule(schedule)
      {:ok, _again} = MishkaPay.create_subscription_schedule(schedule)

      assert_received {:stripe, "POST", "/v1/subscription_schedules", params, [key]}

      assert params == %{
               "customer" => "cus_1",
               "billing_mode" => %{
                 "type" => "flexible",
                 "flexible" => %{"proration_discounts" => "itemized"}
               },
               "start_date" => "1796083200",
               "end_behavior" => "cancel",
               "phases" => %{
                 "0" => %{
                   "items" => %{"0" => %{"price" => "price_intro", "quantity" => "1"}},
                   "duration" => %{"interval" => "month", "interval_count" => "3"},
                   "trial" => "true"
                 },
                 "1" => %{
                   "items" => %{"0" => %{"price" => "price_full", "quantity" => "2"}},
                   "end_date" => "1827619200"
                 }
               },
               "metadata" => %{"mishka_pay_reference" => "member-7"}
             }

      assert_received {:stripe, "POST", "/v1/subscription_schedules", _params, [^key]}

      {:ok, _from} =
        MishkaPay.create_subscription_schedule(%{provider: "stripe", subscription_id: "sub_1"})

      assert_received {:stripe, "POST", "/v1/subscription_schedules",
                       %{"from_subscription" => "sub_1"} = from, _key}

      assert map_size(from) == 1
      refute_received {:stripe, "POST", "/v1/subscription_schedules/sub_sched_1", _params, _key}

      # Stripe takes no metadata with from_subscription: the reference goes on in a change.
      {:ok, _labelled} =
        MishkaPay.create_subscription_schedule(%{
          provider: "stripe",
          subscription_id: "sub_1",
          reference: "from-1"
        })

      assert_received {:stripe, "POST", "/v1/subscription_schedules",
                       %{"from_subscription" => "sub_1"} = again, [_key]}

      assert map_size(again) == 1

      assert_received {:stripe, "POST", "/v1/subscription_schedules/sub_sched_1",
                       %{"metadata" => %{"mishka_pay_reference" => "from-1"}} = labels, _key}

      assert map_size(labels) == 1

      {:ok, _changed} =
        MishkaPay.update_subscription_schedule(%{
          provider: "stripe",
          id: "sub_sched_1",
          end_behavior: :release
        })

      assert_received {:stripe, "POST", "/v1/subscription_schedules/sub_sched_1",
                       %{"end_behavior" => "release"} = change, _key}

      assert map_size(change) == 1

      {:ok, _canceled} =
        MishkaPay.cancel_subscription_schedule("stripe", "sub_sched_1", nil, prorate: true)

      assert_received {:stripe, "POST", "/v1/subscription_schedules/sub_sched_1/cancel",
                       %{"prorate" => "true"} = cancel, _key}

      assert map_size(cancel) == 1
    end

    test "a schedule that cannot be right is refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
      phase = %{items: [%{id: "price_1"}]}
      base = %{provider: "stripe", customer_id: "cus_1", phases: [phase]}

      for {attrs, field} <- [
            {Map.delete(base, :phases), :phases},
            {%{base | phases: []}, :phases},
            {Map.delete(base, :customer_id), :customer_id},
            {Map.put(base, :subscription_id, "sub_1"), :customer_id},
            {%{provider: "stripe", subscription_id: "sub_1", end_behavior: :cancel},
             :end_behavior},
            {%{provider: "stripe", subscription_id: "sub_1", billing_mode: :flexible},
             :billing_mode},
            {Map.merge(base, %{billing_mode: :classic, proration_discounts: :itemized}),
             :proration_discounts},
            {Map.put(base, :billing_mode, :monthly), :billing_mode},
            {%{base | phases: [%{items: []}]}, :items},
            {%{
               base
               | phases: [%{items: [%{name: "Pro", amount: %{amount: "9", currency: "USD"}}]}]
             }, :items},
            {%{base | phases: [Map.put(phase, :iterations, 3)]}, :iterations},
            {%{
               base
               | phases: [
                   Map.merge(phase, %{
                     iterations: 3,
                     interval: :month,
                     end_at: ~U[2027-01-01 00:00:00Z]
                   })
                 ]
             }, :iterations},
            {%{base | phases: [Map.put(phase, :interval, :fortnight)]}, :interval},
            {Map.put(base, :end_behavior, :renew), :end_behavior},
            {%{base | customer_id: "sub_1"}, :customer_id},
            {%{base | phases: [%{items: [%{id: "prod_1"}]}]}, :phases},
            {%{provider: "stripe", subscription_id: "cus_1"}, :subscription_id}
          ] do
        assert {:error, %Errors.Invalid{errors: errors}} =
                 MishkaPay.create_subscription_schedule(attrs)

        # A phase's own error comes inside the error on :phases.
        fields =
          Enum.flat_map(
            errors,
            &[&1.field | Enum.map(&1.child_errors || [], fn e -> e.field end)]
          )

        assert field in fields, inspect({attrs, errors})
      end

      for {attrs, field} <- [
            {%{provider: "stripe", id: "sub_sched_1", customer_id: "cus_2"}, :customer_id},
            {%{provider: "stripe", id: "sub_sched_1", subscription_id: "sub_2"},
             :subscription_id},
            {%{provider: "stripe", end_behavior: :cancel}, :id},
            {%{provider: "stripe", id: "sub_1", end_behavior: :cancel}, :schedule_id},
            {%{provider: "stripe", id: "sub_sched_1", billing_mode: :classic}, :billing_mode},
            {%{provider: "stripe", id: "sub_sched_1", proration_discounts: :included},
             :proration_discounts}
          ] do
        assert {:error, %Errors.Invalid{errors: [%{field: ^field}]}} =
                 MishkaPay.update_subscription_schedule(attrs)
      end

      for call <- [
            fn ->
              MishkaPay.fetch_subscription_schedule("stripe", "sub_sched_1/../../v1/charges")
            end,
            fn -> MishkaPay.release_subscription_schedule("stripe", "sub_1") end,
            fn -> MishkaPay.cancel_subscription_schedule("stripe", "cus_1") end
          ] do
        assert {:error, %Errors.Invalid{errors: [%{field: :schedule_id}]}} = call.()
      end

      assert {:error, %Errors.Invalid{errors: [%{field: :customer_id}]}} =
               MishkaPay.list_subscription_schedules("stripe", nil, customer_id: "sub_1")
    end

    test "credit notes are made, previewed, read, voided and listed with their lines as Stripe's spec accepts" do
      note = %{
        provider: "stripe",
        tenant: "site-a",
        invoice_id: "in_123",
        lines: [
          %{invoice_line_id: "il_123", quantity: 1},
          %{name: "Goodwill", unit_amount: %{amount: "5.00", currency: "USD"}}
        ],
        reason: :order_change,
        refund_amount: %{amount: "10.00", currency: "USD"},
        credit_amount: %{amount: "2.00", currency: "USD"},
        memo: "Sorry for the wait",
        reference: "credit-1",
        metadata: %{"team" => "ops"}
      }

      assert {:ok, %MishkaPay.CreditNote{id: "cn_" <> _, status: :issued, lines: [_ | _]}} =
               MishkaPay.preview_credit_note(note)

      assert {:ok, %MishkaPay.CreditNote{id: "cn_" <> _ = id, provider: "stripe"}} =
               MishkaPay.create_credit_note(note)

      assert {:ok, %MishkaPay.CreditNote{}} =
               MishkaPay.create_credit_note(%{
                 provider: "stripe",
                 invoice_id: "in_123",
                 amount: %{amount: "1.00", currency: "USD"},
                 out_of_band_amount: %{amount: "1.00", currency: "USD"}
               })

      assert {:ok, %MishkaPay.CreditNote{id: ^id}} =
               MishkaPay.fetch_credit_note("stripe", id, "site-a")

      assert {:ok, %MishkaPay.CreditNote{}} = MishkaPay.void_credit_note("stripe", id, "site-a")

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.CreditNote{} | _]}} =
               MishkaPay.list_credit_notes("stripe", "site-a", invoice_id: "in_123", limit: 3)

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.CreditNoteLine{amount: %Money{}} | _]}} =
               MishkaPay.list_credit_note_lines("stripe", id, "site-a", limit: 2)
    end

    test "a credit note goes to Stripe by line or by amount, keyed by its reference" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        key = Plug.Conn.get_req_header(conn, "idempotency-key")
        params = Plug.Conn.Query.decode(Enum.join([conn.query_string, body], "&"))
        send(test, {:stripe, conn.method, conn.request_path, params, key})

        Req.Test.json(conn, %{
          "object" => "credit_note",
          "id" => "cn_1",
          "currency" => "eur",
          "status" => "issued"
        })
      end)

      note = %{
        provider: "stripe",
        tenant: "site-a",
        invoice_id: "in_1",
        lines: [
          %{invoice_line_id: "il_1", amount: %{amount: "3.50", currency: "EUR"}},
          %{name: "Late delivery", unit_amount: %{amount: "2", currency: "EUR"}, quantity: 2}
        ],
        refund_amount: %{amount: "7.50", currency: "EUR"},
        reason: "product_unsatisfactory",
        reference: "credit-7"
      }

      {:ok, _note} = MishkaPay.create_credit_note(note)
      {:ok, _again} = MishkaPay.create_credit_note(note)

      assert_received {:stripe, "POST", "/v1/credit_notes", params, [key]}

      assert params == %{
               "invoice" => "in_1",
               "lines" => %{
                 "0" => %{
                   "type" => "invoice_line_item",
                   "invoice_line_item" => "il_1",
                   "amount" => "350"
                 },
                 "1" => %{
                   "type" => "custom_line_item",
                   "description" => "Late delivery",
                   "quantity" => "2",
                   "unit_amount_decimal" => "200"
                 }
               },
               "refund_amount" => "750",
               "reason" => "product_unsatisfactory",
               "metadata" => %{"mishka_pay_reference" => "credit-7"}
             }

      assert_received {:stripe, "POST", "/v1/credit_notes", _params, [^key]}

      {:ok, _preview} =
        MishkaPay.preview_credit_note(%{
          provider: "stripe",
          invoice_id: "in_1",
          amount: %{amount: "1", currency: "EUR"},
          credit_amount: %{amount: "1", currency: "EUR"}
        })

      assert_received {:stripe, "GET", "/v1/credit_notes/preview", preview, []}

      assert preview == %{"invoice" => "in_1", "amount" => "100", "credit_amount" => "100"}
    end

    test "a credit note that cannot be right is refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
      usd = fn amount -> %{amount: amount, currency: "USD"} end
      base = %{provider: "stripe", invoice_id: "in_123", amount: usd.("5")}
      lined = fn line -> base |> Map.delete(:amount) |> Map.put(:lines, [line]) end

      for {attrs, field} <- [
            {Map.delete(base, :amount), :amount},
            {Map.put(base, :lines, [%{invoice_line_id: "il_1", quantity: 1}]), :amount},
            {Map.delete(base, :invoice_id), :invoice_id},
            {%{base | invoice_id: "sub_1"}, :invoice_id},
            {Map.put(base, :refund_amount, %{amount: "5", currency: "EUR"}), :amount},
            {Map.put(base, :reason, :requested_by_customer), :reason},
            {%{base | amount: %{amount: "1.005", currency: "KWD"}}, :amount},
            {lined.(%{invoice_line_id: "il_1"}), :lines},
            {lined.(%{name: "Credit"}), :lines},
            {lined.(%{invoice_line_id: "ii_1", quantity: 1}), :lines}
          ] do
        assert {:error, %Errors.Invalid{errors: errors}} = MishkaPay.create_credit_note(attrs)
        assert Enum.any?(errors, &(&1.field == field)), inspect({attrs, errors})
      end

      for call <- [
            fn -> MishkaPay.fetch_credit_note("stripe", "cn_1/../../v1/charges") end,
            fn -> MishkaPay.void_credit_note("stripe", "in_1") end,
            fn -> MishkaPay.list_credit_note_lines("stripe", "cnli_1") end
          ] do
        assert {:error, %Errors.Invalid{errors: [%{field: :credit_note_id}]}} = call.()
      end

      assert {:error, %Errors.Invalid{errors: [%{field: :invoice_id}]}} =
               MishkaPay.list_credit_notes("stripe", nil, invoice_id: "cus_1")
    end

    test "an invoice item that cannot be right is refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
      base = %{provider: "stripe", customer_id: "cus_123", price_id: "price_123"}

      for {attrs, field} <- [
            {Map.delete(base, :price_id), :amount},
            {%{base | customer_id: "cs_1"}, :customer_id},
            {Map.delete(base, :customer_id), :customer_id},
            {%{base | price_id: "prod_1"}, :price_id},
            {Map.put(base, :invoice_id, "sub_1"), :invoice_id},
            {Map.merge(base, %{
               price_id: nil,
               name: "Fee",
               amount: %{amount: "1.005", currency: "KWD"}
             }), :amount}
          ] do
        assert {:error, %Errors.Invalid{errors: errors}} = MishkaPay.create_invoice_item(attrs)
        assert Enum.any?(errors, &(&1.field == field)), inspect({attrs, errors})
      end

      for {attrs, field} <- [
            {%{provider: "stripe", id: "ii_1", customer_id: "cus_2"}, :customer_id},
            {%{provider: "stripe", id: "ii_1", invoice_id: "in_2"}, :invoice_id},
            {%{provider: "stripe", id: "in_1", quantity: 2}, :id},
            {%{provider: "stripe", quantity: 2}, :id}
          ] do
        assert {:error, %Errors.Invalid{errors: [%{field: ^field}]}} =
                 MishkaPay.update_invoice_item(attrs)
      end

      assert {:error, %Errors.Invalid{errors: [%{field: :invoice_item_id}]}} =
               MishkaPay.delete_invoice_item("stripe", "ii_1/../../v1/charges")

      assert {:error, %Errors.Invalid{errors: [%{field: :customer_id}]}} =
               MishkaPay.list_invoice_items("stripe", nil, customer_id: "in_1")
    end

    test "a bill that cannot be right is refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
      line = %{name: "Setup", amount: %{amount: "10", currency: "USD"}}
      base = %{provider: "stripe", customer_id: "cus_123", items: [line]}

      for {attrs, field} <- [
            {%{base | items: []}, :items},
            {%{base | items: [Map.put(line, :interval, :month)]}, :items},
            {%{base | items: [line, %{line | amount: %{amount: "1", currency: "EUR"}}]}, :items},
            {Map.put(base, :days_until_due, 5), :days_until_due},
            {%{base | customer_id: "cs_1"}, :customer_id},
            {%{base | items: [%{id: "prod_1"}]}, :items}
          ] do
        assert {:error, %Errors.Invalid{errors: errors}} = MishkaPay.create_invoice(attrs)
        assert Enum.any?(errors, &(&1.field == field)), inspect({attrs, errors})
      end

      assert {:error, %Errors.Invalid{errors: [%{field: :invoice_id}]}} =
               MishkaPay.finalize_invoice("stripe", "cus_1")
    end

    test "customers are searched by email, name and reference, and a subscription's next bill is read" do
      test_pid = self()

      MishkaPay.Test.stub_http(fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:query, conn.request_path, conn.query_params})
        StripeMock.forward(conn)
      end)

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.Customer{} | _]}} =
               MishkaPay.search_customers("stripe", "site-a",
                 email: "ava@example.com",
                 reference: "user's-1"
               )

      assert_received {:query, "/v1/customers/search", %{"query" => query}}

      assert query ==
               ~S(email:'ava@example.com' AND metadata['mishka_pay_reference']:'user\'s-1')

      assert {:ok, %Invoice{}} = MishkaPay.upcoming_invoice("stripe", "sub_123", "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :query}]}} =
               MishkaPay.search_customers("stripe", "site-a", limit: 5)
    end

    test "a checkout with terms, a phone, questions, a description and a statement suffix goes as Stripe's spec accepts" do
      checkout =
        Map.merge(@checkout, %{
          terms: true,
          phone: true,
          description: "Order 42",
          statement_suffix: "ORDER 42",
          submit_type: :book,
          fields: [
            %{key: "certname", label: "Name on the certificate"},
            %{
              key: "seat",
              label: "Seat",
              type: :dropdown,
              options: [%{value: "a", label: "Front"}, %{value: "b", label: "Back"}],
              optional: true
            }
          ]
        })

      assert {:ok, %Checkout{id: "cs_" <> _}} = MishkaPay.checkout(checkout)

      params = Stripe.Mapper.checkout_params(elem(Checkout.builder(checkout), 1))
      assert params["consent_collection"] == %{"terms_of_service" => "required"}
      assert params["phone_number_collection"] == %{"enabled" => true}
      assert params["submit_type"] == "book"

      assert params["payment_intent_data"]["statement_descriptor_suffix"] == "ORDER 42"

      assert [%{"type" => "text"}, %{"type" => "dropdown", "dropdown" => %{"options" => [_, _]}}] =
               params["custom_fields"]

      trial =
        Map.merge(@checkout, %{
          mode: :subscription,
          items: [%{name: "Pro", amount: %{amount: "9", currency: "USD"}, interval: :month}],
          trial_days: 14,
          card_required: false
        })

      assert {:ok, %Checkout{}} = MishkaPay.checkout(trial)
      params = Stripe.Mapper.checkout_params(elem(Checkout.builder(trial), 1))
      assert params["payment_method_collection"] == "if_required"
    end

    test "checkout options that do not fit are refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
      field = %{key: "a", label: "A"}

      for {changes, field_name} <- [
            {%{fields: [field, %{field | key: "b"}, %{field | key: "c"}, %{field | key: "d"}]},
             :fields},
            {%{fields: [%{key: "bad key", label: "A"}]}, :fields},
            {%{fields: [%{key: "a", label: "A", type: :dropdown}]}, :fields},
            {%{card_required: false}, :card_required},
            {%{statement_suffix: "no-dashes"}, :statement_suffix},
            {%{statement_suffix: "ORDER 1", merchant_of_record: true}, :statement_suffix}
          ] do
        assert {:error, %Errors.Invalid{errors: errors}} =
                 MishkaPay.checkout(Map.merge(@checkout, changes))

        assert Enum.any?(errors, &(&1.field == field_name)), inspect({changes, errors})
      end
    end

    test "a setup checkout saves a card without a charge, as Stripe's spec accepts" do
      setup = %{
        provider: "stripe",
        tenant: "site-a",
        mode: :setup,
        currency: "eur",
        success_url: "https://shop.test/saved",
        cancel_url: "https://shop.test/account",
        reference: "card-1",
        description: "Card for renewals"
      }

      assert {:ok, %Checkout{id: "cs_" <> _, mode: :setup}} =
               MishkaPay.checkout(Map.put(setup, :customer, %{id: "cus_123"}))

      assert {:ok, %Checkout{id: "cs_" <> _}} = MishkaPay.checkout(setup)

      assert {:ok, %Checkout{id: "cs_" <> _}} =
               MishkaPay.fetch_checkout("stripe", "cs_123", "site-a")

      {:ok, known} = Checkout.builder(Map.put(setup, :customer, %{id: "cus_123"}))

      params =
        Stripe.Mapper.checkout_params(known, %{automatic_tax: true, merchant_of_record: true})

      assert {params["mode"], params["currency"], params["customer"]} ==
               {"setup", "eur", "cus_123"}

      assert params["setup_intent_data"] == %{
               "metadata" => %{"mishka_pay_reference" => "card-1"},
               "description" => "Card for renewals"
             }

      assert params["managed_payments"] == %{"enabled" => false}

      for sold <- ~w(line_items customer_creation automatic_tax payment_intent_data) do
        refute Map.has_key?(params, sold), sold
      end

      {:ok, new_buyer} = Checkout.builder(setup)
      assert Stripe.Mapper.checkout_params(new_buyer)["customer_creation"] == "always"
    end

    test "saved payment methods are listed, read, made the default and taken off, as Stripe's spec answers" do
      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.PaymentMethod{id: "pm_" <> _} | _]}} =
               MishkaPay.list_payment_methods("stripe", "site-a",
                 customer_id: "cus_123",
                 limit: 3
               )

      assert {:ok, %MishkaPay.PaymentMethod{provider: "stripe", id: "pm_" <> _, type: "card"}} =
               MishkaPay.fetch_payment_method("stripe", "pm_123", "site-a")

      assert {:ok, %MishkaPay.Customer{id: "cus_" <> _}} =
               MishkaPay.set_default_payment_method("stripe", "cus_123", "pm_123", "site-a")

      assert {:ok, %MishkaPay.PaymentMethod{id: "pm_" <> _}} =
               MishkaPay.detach_payment_method("stripe", "pm_123", "site-a")
    end

    test "a setup checkout or a payment method call that cannot be right is refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)

      setup =
        @checkout
        |> Map.drop([:items, :customer])
        |> Map.merge(%{mode: :setup, currency: "usd"})

      for {attrs, field} <- [
            {Map.delete(setup, :currency), :currency},
            {Map.put(setup, :currency, "dollars"), :currency},
            {Map.put(setup, :items, @checkout.items), :items},
            {Map.put(setup, :trial_days, 7), :trial_days},
            {Map.put(setup, :allow_promotion_codes, true), :allow_promotion_codes},
            {Map.put(setup, :automatic_tax, false), :automatic_tax},
            {Map.put(setup, :submit_type, :pay), :submit_type},
            {Map.put(@checkout, :currency, "usd"), :currency}
          ] do
        assert {:error, %Errors.Invalid{errors: errors}} = MishkaPay.checkout(attrs)
        assert Enum.any?(errors, &(&1.field == field)), inspect({attrs, errors})
      end

      assert {:error, %Errors.Invalid{errors: [%{field: :customer_id}]}} =
               MishkaPay.list_payment_methods("stripe", "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :customer_id}]}} =
               MishkaPay.list_payment_methods("stripe", "site-a", customer_id: "pm_1")

      assert {:error, %Errors.Invalid{errors: [%{field: :payment_method_id}]}} =
               MishkaPay.fetch_payment_method("stripe", "pm_1/../../v1/charges", "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :payment_method_id}]}} =
               MishkaPay.detach_payment_method("stripe", "cus_1", "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :customer_id}]}} =
               MishkaPay.set_default_payment_method("stripe", "pm_1", "pm_1", "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :payment_method_id}]}} =
               MishkaPay.set_default_payment_method("stripe", "cus_1", "seti_1", "site-a")
    end

    test "portal configurations are made, changed, read and listed as Stripe's spec accepts, and a session names one" do
      assert {:ok, %MishkaPay.PortalConfiguration{id: "bpc_" <> _ = id, provider: "stripe"}} =
               MishkaPay.create_portal_configuration(%{
                 provider: "stripe",
                 tenant: "site-a",
                 name: "Teams",
                 headline: "Acme Teams billing",
                 privacy_policy_url: "https://shop.test/privacy",
                 terms_of_service_url: "https://shop.test/terms",
                 default_return_url: "https://shop.test/account",
                 invoice_history: true,
                 payment_method_update: true,
                 customer_update: ["email", :address, :tax_id],
                 subscription_cancel: "at_period_end",
                 subscription_update: [:price, :quantity],
                 plans: [%{product_id: "prod_team", price_ids: ["price_month", "price_year"]}],
                 proration: :always_invoice,
                 metadata: %{"for" => "teams"}
               })

      assert {:ok, %MishkaPay.PortalConfiguration{}} =
               MishkaPay.update_portal_configuration(%{
                 provider: "stripe",
                 tenant: "site-a",
                 id: "bpc_123",
                 active: false,
                 subscription_cancel: :off,
                 customer_update: []
               })

      assert {:ok, %MishkaPay.PortalConfiguration{id: "bpc_123"}} =
               MishkaPay.fetch_portal_configuration("stripe", "bpc_123", "site-a")

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.PortalConfiguration{} | _]}} =
               MishkaPay.list_portal_configurations("stripe", "site-a", active: true, limit: 3)

      assert {:ok, %MishkaPay.PortalSession{url: "https://" <> _}} =
               MishkaPay.portal_session(%{
                 provider: "stripe",
                 tenant: "site-a",
                 customer_id: "cus_123",
                 return_url: "https://shop.test/account",
                 configuration: id
               })
    end

    test "a portal configuration goes to Stripe as its features, and only what a change names" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:stripe, conn.request_path, URI.decode_query(body)})
        Req.Test.json(conn, %{"object" => "billing_portal.configuration", "id" => "bpc_1"})
      end)

      {:ok, _made} =
        MishkaPay.create_portal_configuration(%{
          provider: "stripe",
          headline: "Billing",
          invoice_history: false,
          customer_update: [:email, :name],
          subscription_cancel: :immediately,
          subscription_update: [:price],
          plans: [%{product_id: "prod_1", price_ids: ["price_a", "price_b"]}],
          proration: :none
        })

      assert_received {:stripe, "/v1/billing_portal/configurations", params}

      assert params == %{
               "business_profile[headline]" => "Billing",
               "features[invoice_history][enabled]" => "false",
               "features[customer_update][enabled]" => "true",
               "features[customer_update][allowed_updates][0]" => "email",
               "features[customer_update][allowed_updates][1]" => "name",
               "features[subscription_cancel][enabled]" => "true",
               "features[subscription_cancel][mode]" => "immediately",
               "features[subscription_update][enabled]" => "true",
               "features[subscription_update][default_allowed_updates][0]" => "price",
               "features[subscription_update][products][0][product]" => "prod_1",
               "features[subscription_update][products][0][prices][0]" => "price_a",
               "features[subscription_update][products][0][prices][1]" => "price_b",
               "features[subscription_update][proration_behavior]" => "none",
               "expand[0]" => "features.subscription_update.products"
             }

      {:ok, _changed} =
        MishkaPay.update_portal_configuration(%{
          provider: "stripe",
          id: "bpc_1",
          subscription_update: []
        })

      assert_received {:stripe, "/v1/billing_portal/configurations/bpc_1", change}

      assert change == %{
               "features[subscription_update][enabled]" => "false",
               "expand[0]" => "features.subscription_update.products"
             }
    end

    test "a portal configuration or session that cannot be right is refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
      base = %{provider: "stripe", subscription_update: [:price]}

      for {attrs, field} <- [
            {Map.put(base, :customer_update, [:email, :password]), :customer_update},
            {Map.put(base, :subscription_update, ["seats"]), :subscription_update},
            {Map.put(base, :subscription_cancel, :later), :subscription_cancel},
            {Map.put(base, :proration, :sometimes), :proration},
            {Map.put(base, :plans, [%{product_id: "prod_1", price_ids: []}]), :plans},
            {Map.put(base, :plans, [%{product_id: "prod_1", price_ids: ["prod_2"]}]), :plans},
            {Map.put(base, :plans, [%{product_id: "prod/../1", price_ids: ["price_1"]}]), :plans}
          ] do
        assert {:error, %Errors.Invalid{errors: errors}} =
                 MishkaPay.create_portal_configuration(attrs)

        assert Enum.any?(errors, &(&1.field == field)), inspect({attrs, errors})
      end

      assert {:error, %Errors.Invalid{errors: [%{field: :id}]}} =
               MishkaPay.update_portal_configuration(%{provider: "stripe", id: "cus_1"})

      assert {:error, %Errors.Invalid{errors: [%{field: :configuration_id}]}} =
               MishkaPay.fetch_portal_configuration("stripe", "bpc_1/../../v1/charges")

      assert {:error, %Errors.Invalid{errors: [%{field: :configuration}]}} =
               MishkaPay.portal_session(%{
                 provider: "stripe",
                 customer_id: "cus_1",
                 return_url: "https://shop.test/account",
                 configuration: "pi_1"
               })
    end

    test "a portal task the portal's settings turn off is a plain refusal that says where to turn it on" do
      MishkaPay.Test.stub_http(fn conn ->
        error = %{
          "type" => "invalid_request_error",
          "message" =>
            "This subscription cannot be updated because the subscription update feature in the portal configuration is disabled."
        }

        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => error})
      end)

      assert {:error, %Errors.Rejected{code: "portal_feature_off"} = error} =
               MishkaPay.portal_session(%{
                 provider: "stripe",
                 tenant: "site-a",
                 customer_id: "cus_123",
                 return_url: "https://shop.test/account",
                 flow: :subscription_update,
                 subscription_id: "sub_123"
               })

      assert Exception.message(error) =~ "portal's settings"

      MishkaPay.Test.stub_http(fn conn ->
        error = %{
          "type" => "invalid_request_error",
          "message" => "The session's customer does not match the subscription's customer."
        }

        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => error})
      end)

      assert {:error, %Errors.Rejected{code: "subscription_of_another"}} =
               MishkaPay.portal_session(%{
                 provider: "stripe",
                 customer_id: "cus_123",
                 return_url: "https://shop.test/account",
                 flow: :subscription_cancel,
                 subscription_id: "sub_123"
               })
    end

    test "an intent an invoice or a checkout made is refused a cancel in plain words, keeping Stripe's for the log" do
      refusals = [
        {"You cannot cancel PaymentIntents created by invoices. Try voiding the invoice instead.",
         "intent_of_invoice", "void the bill"},
        {"You cannot perform this action on PaymentIntents created by Checkout.",
         "intent_of_checkout", "end the checkout"}
      ]

      for {words, code, advice} <- refusals do
        MishkaPay.Test.stub_http(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("request-id", "req_cancel1")
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"error" => %{"type" => "invalid_request_error", "message" => words}})
        end)

        assert {:error,
                %Errors.Rejected{status: 400, code: ^code, request_id: "req_cancel1"} = error} =
                 MishkaPay.cancel_payment_intent("stripe", "pi_123", "site-a")

        assert error.message == words
        assert Exception.message(error) =~ advice
        refute Exception.message(error) =~ "HTTP 400"
      end

      MishkaPay.Test.stub_http(fn conn ->
        error = %{
          "type" => "invalid_request_error",
          "message" => "This PaymentIntent's status is succeeded, and it cannot be canceled."
        }

        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => error})
      end)

      assert {:error, %Errors.Rejected{status: 400, code: nil} = error} =
               MishkaPay.cancel_payment_intent("stripe", "pi_123", "site-a")

      assert Exception.message(error) =~ "HTTP 400"
    end

    test "a portal session opens on one task, as Stripe's spec accepts, and a subscription task needs its subscription" do
      base = %{
        provider: "stripe",
        tenant: "site-a",
        customer_id: "cus_123",
        return_url: "https://shop.test/account"
      }

      for flow <- [:subscription_cancel, :subscription_update] do
        assert {:ok, %MishkaPay.PortalSession{url: "https://" <> _}} =
                 MishkaPay.portal_session(
                   Map.merge(base, %{flow: flow, subscription_id: "sub_123"})
                 )
      end

      assert {:ok, %MishkaPay.PortalSession{}} =
               MishkaPay.portal_session(Map.put(base, :flow, :payment_method_update))

      {:ok, session} =
        MishkaPay.PortalSession.builder(
          Map.merge(base, %{flow: :subscription_cancel, subscription_id: "sub_1"})
        )

      assert %{
               "type" => "subscription_cancel",
               "subscription_cancel" => %{"subscription" => "sub_1"},
               "after_completion" => %{
                 "redirect" => %{"return_url" => "https://shop.test/account"}
               }
             } = Stripe.Mapper.portal_flow(session)

      assert {:error, %Errors.Invalid{errors: [%{field: :subscription_id}]}} =
               MishkaPay.portal_session(Map.put(base, :flow, :subscription_cancel))
    end

    test "a choice Stripe takes only with Managed Payments off is a plain refusal naming it" do
      MishkaPay.Test.stub_http(fn conn ->
        error = %{
          "type" => "invalid_request_error",
          "message" =>
            "payment_intent_data.statement_descriptor_suffix cannot be used with Managed Payments, which is enabled by default on your account."
        }

        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => error})
      end)

      assert {:error,
              %Errors.Rejected{code: "merchant_of_record_off", param: "statement_suffix"} = error} =
               MishkaPay.checkout(Map.put(@checkout, :statement_suffix, "ORDER 1"))

      assert Exception.message(error) =~ "merchant_of_record to false"
    end

    test "early fraud warnings and open reviews are read and listed, and a review approved, as Stripe's spec accepts" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        send(test, {:sent, conn.method, conn.request_path, conn.query_string})
        StripeMock.forward(conn)
      end)

      assert {:ok,
              %MishkaPay.FraudWarning{
                id: "issfr_123",
                charge_id: "ch_1234",
                fraud_type: "misc",
                actionable: true,
                created_at: %DateTime{}
              }} = MishkaPay.fetch_fraud_warning("stripe", "issfr_123", "site-a")

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.FraudWarning{id: "issfr_" <> _}]}} =
               MishkaPay.list_fraud_warnings("stripe", "site-a", payment_id: "pi_1", limit: 5)

      assert_received {:sent, "GET", "/v1/radar/early_fraud_warnings/issfr_123", ""}
      assert_received {:sent, "GET", "/v1/radar/early_fraud_warnings", query}
      assert %{"payment_intent" => "pi_1", "limit" => "5"} = URI.decode_query(query)

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.FraudReview{open: true} | _]}} =
               MishkaPay.list_fraud_reviews("stripe", "site-a")

      assert {:ok,
              %MishkaPay.FraudReview{id: "prv_123", opened_reason: :rule, charge_id: "ch_" <> _}} =
               MishkaPay.fetch_fraud_review("stripe", "prv_123", "site-a")

      assert {:ok, %MishkaPay.FraudReview{id: "prv_123"}} =
               MishkaPay.approve_fraud_review("stripe", "prv_123", "site-a")

      assert_received {:sent, "POST", "/v1/reviews/prv_123/approve", ""}
    end

    test "a payment intent is made, read, changed, confirmed and canceled as Stripe's spec accepts" do
      test = self()
      MishkaPay.Test.stub_http(&StripeMock.forward_telling(&1, test))

      intent = %{
        provider: "stripe",
        tenant: "site-a",
        amount: %{amount: "19.99", currency: "EUR"},
        customer_id: "cus_123",
        capture: :manual,
        setup_future_usage: :off_session,
        description: "Ebook",
        reference: "order-9",
        owner: "user-1"
      }

      assert {:ok, %MishkaPay.PaymentIntent{id: "pi_" <> _, client_secret: secret}} =
               MishkaPay.create_payment_intent(intent)

      assert secret =~ "_secret_"
      assert_received {:stripe_sent, "POST", "/v1/payment_intents", sent, key}

      assert sent == %{
               "amount" => "1999",
               "currency" => "eur",
               "customer" => "cus_123",
               "capture_method" => "manual",
               "setup_future_usage" => "off_session",
               "automatic_payment_methods[enabled]" => "true",
               "description" => "Ebook",
               "metadata[mishka_pay_reference]" => "order-9",
               "metadata[mishka_pay_owner]" => "user-1"
             }

      assert key =~ "payment-intent"

      assert {:ok, %MishkaPay.PaymentIntent{id: "pi_123", status: status}} =
               MishkaPay.fetch_payment_intent("stripe", "pi_123", "site-a")

      assert status in MishkaPay.PaymentIntent.statuses()

      assert {:ok, %MishkaPay.PaymentIntent{}} =
               MishkaPay.update_payment_intent(%{
                 provider: "stripe",
                 tenant: "site-a",
                 id: "pi_123",
                 amount: %{amount: "25", currency: "EUR"}
               })

      assert_received {:stripe_sent, "GET", "/v1/payment_intents/pi_123", _query, _key}

      assert_received {:stripe_sent, "POST", "/v1/payment_intents/pi_123",
                       %{"amount" => "2500", "currency" => "eur"} = change, _key}

      assert map_size(change) == 2

      assert {:ok, %MishkaPay.PaymentIntent{}} =
               MishkaPay.confirm_payment_intent("stripe", "pi_123", "site-a",
                 payment_method_id: "pm_card_visa",
                 return_url: "https://shop.test/paid"
               )

      assert_received {:stripe_sent, "POST", "/v1/payment_intents/pi_123/confirm",
                       %{
                         "payment_method" => "pm_card_visa",
                         "return_url" => "https://shop.test/paid"
                       }, _key}

      assert {:ok, %MishkaPay.PaymentIntent{}} =
               MishkaPay.cancel_payment_intent("stripe", "pi_123", "site-a")

      assert_received {:stripe_sent, "POST", "/v1/payment_intents/pi_123/cancel", _params, _key}

      assert {:ok, %Payment{id: "pi_123"}} = MishkaPay.fetch_payment("stripe", "pi_123", "site-a")
    end

    test "a setup intent is made, read, confirmed and canceled as Stripe's spec accepts" do
      test = self()
      MishkaPay.Test.stub_http(&StripeMock.forward_telling(&1, test))

      assert {:ok, %MishkaPay.SetupIntent{id: "seti_" <> _, client_secret: secret}} =
               MishkaPay.create_setup_intent(%{
                 provider: "stripe",
                 tenant: "site-a",
                 customer_id: "cus_123",
                 usage: "on_session",
                 automatic_payment_methods: false,
                 reference: "card-1"
               })

      assert secret =~ "_secret_"

      assert_received {:stripe_sent, "POST", "/v1/setup_intents",
                       %{
                         "customer" => "cus_123",
                         "usage" => "on_session",
                         "automatic_payment_methods[enabled]" => "false",
                         "metadata[mishka_pay_reference]" => "card-1"
                       }, key}

      assert key =~ "setup-intent"

      assert {:ok, %MishkaPay.SetupIntent{id: "seti_123"}} =
               MishkaPay.fetch_setup_intent("stripe", "seti_123", "site-a")

      assert {:ok, %MishkaPay.SetupIntent{}} =
               MishkaPay.confirm_setup_intent("stripe", "seti_123", "site-a",
                 payment_method_id: "pm_card_visa"
               )

      assert_received {:stripe_sent, "POST", "/v1/setup_intents/seti_123/confirm",
                       %{"payment_method" => "pm_card_visa"} = confirm, _key}

      assert map_size(confirm) == 1

      assert {:ok, %MishkaPay.SetupIntent{}} =
               MishkaPay.cancel_setup_intent("stripe", "seti_123", "site-a")
    end

    test "an intent that cannot be right is refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
      euro = %{amount: "10", currency: "EUR"}

      for {result, field} <- [
            {MishkaPay.fetch_payment_intent("stripe", "pi_1/../../charges"), :payment_intent_id},
            {MishkaPay.fetch_payment_intent("stripe", "seti_1"), :payment_intent_id},
            {MishkaPay.update_payment_intent(%{provider: "stripe", id: "cs_1", amount: euro}),
             :id},
            {MishkaPay.confirm_payment_intent("stripe", "pi_1", nil, payment_method_id: "tok_1"),
             :payment_method_id},
            {MishkaPay.confirm_payment_intent("stripe", "pi_1", nil,
               return_url: "http://shop.test/paid"
             ), :return_url},
            {MishkaPay.cancel_payment_intent("stripe", "pi_1?x=1"), :payment_intent_id},
            {MishkaPay.create_payment_intent(%{
               provider: "stripe",
               amount: euro,
               customer_id: "x"
             }), :customer_id},
            {MishkaPay.create_payment_intent(%{
               provider: "stripe",
               amount: %{amount: "10.5", currency: "ISK"}
             }), :amount},
            {MishkaPay.fetch_setup_intent("stripe", "pi_1"), :setup_intent_id},
            {MishkaPay.confirm_setup_intent("stripe", "seti_1", nil, return_url: "javascript:x"),
             :return_url},
            {MishkaPay.cancel_setup_intent("stripe", "seti_1/../x"), :setup_intent_id},
            {MishkaPay.create_setup_intent(%{provider: "stripe", payment_method_id: "src_1"}),
             :payment_method_id}
          ] do
        assert {:error, %Errors.Invalid{errors: [%{field: ^field}]}} = result
      end
    end

    test "tax rates are made, read, archived and listed as Stripe's spec accepts" do
      test = self()
      MishkaPay.Test.stub_http(&StripeMock.forward_telling(&1, test))

      rate = %{
        provider: "stripe",
        tenant: "site-a",
        display_name: "Sales tax",
        percentage: "7.25",
        inclusive: false,
        country: "us",
        state: "ny",
        jurisdiction: "New York",
        tax_type: "sales_tax",
        description: "NY state",
        reference: "ny-rate"
      }

      assert {:ok, %MishkaPay.TaxRate{id: "txr_" <> _, percentage: %Decimal{}, inclusive: false}} =
               MishkaPay.create_tax_rate(rate)

      assert_received {:stripe_sent, "POST", "/v1/tax_rates", sent, key}

      assert sent == %{
               "display_name" => "Sales tax",
               "percentage" => "7.25",
               "inclusive" => "false",
               "country" => "US",
               "state" => "NY",
               "jurisdiction" => "New York",
               "tax_type" => "sales_tax",
               "description" => "NY state",
               "metadata[mishka_pay_reference]" => "ny-rate"
             }

      assert key =~ "tax-rate"

      assert {:ok, %MishkaPay.TaxRate{id: "txr_123", tax_type: "vat", country: "DE"}} =
               MishkaPay.fetch_tax_rate("stripe", "txr_123", "site-a")

      assert {:ok, %MishkaPay.TaxRate{}} =
               MishkaPay.update_tax_rate(%{provider: "stripe", id: "txr_123", active: false})

      assert_received {:stripe_sent, "GET", "/v1/tax_rates/txr_123", _query, _key}

      assert_received {:stripe_sent, "POST", "/v1/tax_rates/txr_123",
                       %{"active" => "false"} = change, _}

      assert map_size(change) == 1

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.TaxRate{} | _]}} =
               MishkaPay.list_tax_rates("stripe", "site-a", active: true, inclusive: false)

      assert_received {:stripe_sent, "GET", "/v1/tax_rates",
                       %{"active" => "true", "inclusive" => "false"}, _key}
    end

    test "checkouts, draft bills and invoice items take tax rates, as Stripe's spec accepts" do
      test = self()
      MishkaPay.Test.stub_http(&StripeMock.forward_telling(&1, test))

      assert {:ok, %Checkout{}} =
               MishkaPay.checkout(%{
                 @checkout
                 | items: [
                     %{
                       name: "Ebook",
                       amount: %{amount: "10", currency: "USD"},
                       tax_rate_ids: ["txr_1", "txr_2"]
                     },
                     %{id: "price_1", tax_rate_ids: ["txr_1"]}
                   ]
               })

      assert_received {:stripe_sent, "POST", "/v1/checkout/sessions", session, _key}
      assert session["line_items[0][tax_rates][1]"] == "txr_2"
      assert session["line_items[1][tax_rates][0]"] == "txr_1"

      assert {:ok, %Invoice{}} =
               MishkaPay.create_invoice(%{
                 provider: "stripe",
                 tenant: "site-a",
                 customer_id: "cus_123",
                 tax_rate_ids: ["txr_1"],
                 items: [
                   %{name: "Consulting", amount: %{amount: "100", currency: "USD"}},
                   %{id: "price_1", tax_rate_ids: ["txr_2"]}
                 ]
               })

      assert_received {:stripe_sent, "POST", "/v1/invoices", %{"default_tax_rates[0]" => "txr_1"},
                       _}

      assert_received {:stripe_sent, "POST", "/v1/invoiceitems", first, _key}
      refute Map.has_key?(first, "tax_rates[0]")

      assert_received {:stripe_sent, "POST", "/v1/invoiceitems", %{"tax_rates[0]" => "txr_2"},
                       _key}

      assert {:ok, %MishkaPay.InvoiceItem{}} =
               MishkaPay.create_invoice_item(%{
                 provider: "stripe",
                 tenant: "site-a",
                 customer_id: "cus_123",
                 price_id: "price_123",
                 tax_rate_ids: ["txr_3"]
               })

      assert_received {:stripe_sent, "POST", "/v1/invoiceitems", %{"tax_rates[0]" => "txr_3"},
                       _key}
    end

    test "tax registrations are added, listed and ended, and the tax settings read and changed, as Stripe's spec accepts" do
      test = self()
      MishkaPay.Test.stub_http(&StripeMock.forward_telling(&1, test))

      assert {:ok, %MishkaPay.TaxRegistration{id: "taxreg_" <> _}} =
               MishkaPay.create_tax_registration(%{
                 provider: "stripe",
                 tenant: "site-a",
                 country: "de",
                 type: "oss_union"
               })

      assert_received {:stripe_sent, "POST", "/v1/tax/registrations",
                       %{
                         "country" => "DE",
                         "country_options[de][type]" => "oss_union",
                         "active_from" => "now"
                       } = eu, _key}

      assert map_size(eu) == 3

      ends = ~U[2030-01-01 00:00:00Z]

      assert {:ok, %MishkaPay.TaxRegistration{}} =
               MishkaPay.create_tax_registration(%{
                 provider: "stripe",
                 tenant: "site-a",
                 country: "US",
                 type: "state_sales_tax",
                 state: "CA",
                 expires_at: ends
               })

      assert_received {:stripe_sent, "POST", "/v1/tax/registrations",
                       %{"country_options[us][state]" => "CA", "expires_at" => "1893456000"},
                       _key}

      assert {:ok, %MishkaPay.TaxRegistration{}} =
               MishkaPay.create_tax_registration(%{
                 provider: "stripe",
                 tenant: "site-a",
                 country: "CA",
                 type: "province_standard",
                 state: "BC"
               })

      assert_received {:stripe_sent, "POST", "/v1/tax/registrations",
                       %{"country_options[ca][province_standard][province]" => "BC"}, _key}

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.TaxRegistration{} | _]}} =
               MishkaPay.list_tax_registrations("stripe", "site-a", status: :all)

      assert_received {:stripe_sent, "GET", "/v1/tax/registrations", %{"status" => "all"}, _key}

      assert {:ok, %MishkaPay.TaxRegistration{}} =
               MishkaPay.expire_tax_registration("stripe", "taxreg_123", "site-a")

      assert {:ok, %MishkaPay.TaxRegistration{}} =
               MishkaPay.expire_tax_registration("stripe", "taxreg_123", "site-a", at: ends)

      assert_received {:stripe_sent, "POST", "/v1/tax/registrations/taxreg_123",
                       %{"expires_at" => "now"}, _key}

      assert_received {:stripe_sent, "POST", "/v1/tax/registrations/taxreg_123",
                       %{"expires_at" => "1893456000"}, _key}

      assert {:ok,
              %MishkaPay.TaxSettings{
                head_office: %MishkaPay.Address{country: "US"},
                tax_code: "txcd_" <> _,
                status: :active
              }} = MishkaPay.fetch_tax_settings("stripe", "site-a")

      assert {:ok, %MishkaPay.TaxSettings{}} =
               MishkaPay.update_tax_settings(%{
                 provider: "stripe",
                 tenant: "site-a",
                 head_office: %{country: "de", postal_code: "10115", city: "Berlin"},
                 tax_behavior: "exclusive"
               })

      assert_received {:stripe_sent, "POST", "/v1/tax/settings", settings, _key}

      assert settings == %{
               "head_office[address][country]" => "DE",
               "head_office[address][postal_code]" => "10115",
               "head_office[address][city]" => "Berlin",
               "defaults[tax_behavior]" => "exclusive"
             }
    end

    test "a standard registration sends its place of supply scheme where Stripe's spec takes one" do
      test = self()
      MishkaPay.Test.stub_http(&StripeMock.forward_telling(&1, test))

      assert {:ok, %MishkaPay.TaxRegistration{id: "taxreg_" <> _}} =
               MishkaPay.create_tax_registration(%{
                 provider: "stripe",
                 tenant: "site-a",
                 country: "FR",
                 type: "standard",
                 place_of_supply_scheme: "small_seller"
               })

      assert_received {:stripe_sent, "POST", "/v1/tax/registrations",
                       %{
                         "country_options[fr][type]" => "standard",
                         "country_options[fr][standard][place_of_supply_scheme]" => "small_seller"
                       }, _key}

      for {country, scheme} <- [{"GB", :inbound_goods}, {"IS", :standard}, {"DE", :inbound_goods}] do
        assert {:ok, %MishkaPay.TaxRegistration{}} =
                 MishkaPay.create_tax_registration(%{
                   provider: "stripe",
                   tenant: "site-a",
                   country: country,
                   type: "standard",
                   place_of_supply_scheme: scheme
                 })

        code = String.downcase(country)
        type_key = "country_options[#{code}][type]"
        scheme_key = "country_options[#{code}][standard][place_of_supply_scheme]"
        sent = Atom.to_string(scheme)

        assert_received {:stripe_sent, "POST", "/v1/tax/registrations",
                         %{^type_key => "standard", ^scheme_key => ^sent}, _key}
      end
    end

    test "tax rates where Stripe takes none, and tax setups that cannot be right, are refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)

      rated = [
        %{name: "Ebook", amount: %{amount: "10", currency: "USD"}, tax_rate_ids: ["txr_1"]}
      ]

      for {result, field} <- [
            {MishkaPay.fetch_tax_rate("stripe", "txr_1/../charges"), :tax_rate_id},
            {MishkaPay.fetch_tax_rate("stripe", "taxreg_1"), :tax_rate_id},
            {MishkaPay.update_tax_rate(%{provider: "stripe", id: "../x", active: false}), :id},
            {MishkaPay.expire_tax_registration("stripe", "txr_1"), :registration_id},
            {MishkaPay.create_tax_registration(%{
               provider: "stripe",
               country: "US",
               type: "state_sales_tax"
             }), :state},
            {MishkaPay.create_tax_registration(%{
               provider: "stripe",
               country: "CA",
               type: "province_standard"
             }), :state},
            {MishkaPay.create_tax_registration(%{
               provider: "stripe",
               country: "DE",
               type: "standard",
               state: "BY"
             }), :state},
            {MishkaPay.create_tax_registration(%{
               provider: "stripe",
               country: "GB",
               type: "standard",
               place_of_supply_scheme: :small_seller
             }), :place_of_supply_scheme},
            {MishkaPay.create_tax_registration(%{
               provider: "stripe",
               country: "CA",
               type: "standard",
               place_of_supply_scheme: :standard
             }), :place_of_supply_scheme},
            {MishkaPay.create_tax_registration(%{
               provider: "stripe",
               country: "IN",
               type: "simplified",
               place_of_supply_scheme: :standard
             }), :place_of_supply_scheme},
            {MishkaPay.create_tax_registration(%{
               provider: "stripe",
               country: "DE",
               type: "oss_union",
               place_of_supply_scheme: :small_seller
             }), :place_of_supply_scheme},
            {MishkaPay.checkout(%{
               @checkout
               | items: [%{id: "price_1", tax_rate_ids: ["shr_1"]}]
             }), :tax_rate_ids},
            {MishkaPay.checkout(Map.merge(@checkout, %{items: rated, automatic_tax: true})),
             :tax_rate_ids},
            {MishkaPay.create_invoice_item(%{
               provider: "stripe",
               customer_id: "cus_1",
               price_id: "price_1",
               tax_rate_ids: ["txr_1&x=y"]
             }), :tax_rate_ids},
            {MishkaPay.create_price(%{
               provider: "stripe",
               product_id: "ebook",
               amount: %{amount: "10", currency: "USD"},
               tax_rate_ids: ["txr_1"]
             }), :tax_rate_ids},
            {MishkaPay.create_payment_link(%{
               provider: "stripe",
               items: [%{id: "price_1", tax_rate_ids: ["txr_1"]}],
               success_url: "https://shop.test/thanks"
             }), :tax_rate_ids}
          ] do
        assert {:error, %Errors.Invalid{errors: [%{field: ^field}]}} = result
      end

      MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_123", automatic_tax: true})

      assert {:error, %Errors.Invalid{errors: [%{field: :tax_rate_ids, message: message}]}} =
               MishkaPay.checkout(%{@checkout | items: rated})

      assert message =~ "automatic_tax"
    end

    test "a meter is read, renamed, turned on again, and a wrong report is taken back once, as Stripe's spec accepts" do
      test = self()

      MishkaPay.Test.stub_http(fn conn ->
        send(test, {:sent, conn.method, conn.request_path, Map.new(conn.req_headers)})
        StripeMock.forward(conn)
      end)

      assert {:ok, %MishkaPay.Meter{id: "mtr_123", status: :active}} =
               MishkaPay.fetch_meter("stripe", "mtr_123", "site-a")

      assert {:ok, %MishkaPay.Meter{id: "mtr_123", name: "Calls"}} =
               MishkaPay.update_meter(%{
                 provider: "stripe",
                 tenant: "site-a",
                 id: "mtr_123",
                 name: "Calls"
               })

      # stripe-mock answers a fixture of its own for a reactivated meter.
      assert {:ok, %MishkaPay.Meter{status: :active}} =
               MishkaPay.reactivate_meter("stripe", "mtr_123", "site-a")

      assert_received {:sent, "POST", "/v1/billing/meters/mtr_123/reactivate", _headers}

      cancel = %{provider: "stripe", tenant: "site-a", event_name: "api_call", usage_id: "use-1"}

      assert %{"type" => "cancel", "cancel" => %{"identifier" => "use-1"}} =
               Stripe.Mapper.usage_cancellation_params(%MishkaPay.UsageCancellation{
                 provider: "stripe",
                 event_name: "api_call",
                 usage_id: "use-1"
               })

      assert {:ok, %MishkaPay.UsageCancellation{status: :complete, usage_id: "use-1"}} =
               MishkaPay.cancel_usage(cancel)

      assert_received {:sent, "POST", "/v1/billing/meter_event_adjustments",
                       %{"idempotency-key" => "mishka_pay-usage-cancel-" <> _ = key}}

      assert {:ok, %MishkaPay.UsageCancellation{}} = MishkaPay.cancel_usage(cancel)

      assert_received {:sent, "POST", "/v1/billing/meter_event_adjustments",
                       %{"idempotency-key" => ^key}}

      refute key ==
               MishkaPay.ProviderKit.idempotency_key(
                 "usage-cancel",
                 "site-a",
                 {"api_call", "use-2"}
               )
    end

    test "a meter is made, listed and turned off, usage is reported and summed, and a price bills it, as Stripe's spec accepts" do
      # stripe-mock makes its own ids (`meter_...`); Stripe's start with `mtr_`.
      assert {:ok, %MishkaPay.Meter{provider: "stripe", id: "meter_" <> _}} =
               MishkaPay.create_meter(%{
                 provider: "stripe",
                 tenant: "site-a",
                 name: "API calls",
                 event_name: "api_call",
                 aggregation: "count"
               })

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.Meter{status: :active} | _]}} =
               MishkaPay.list_meters("stripe", "site-a", status: :active, limit: 5)

      assert {:ok, %MishkaPay.Meter{}} = MishkaPay.deactivate_meter("stripe", "mtr_123", "site-a")

      assert {:ok, %MishkaPay.Usage{id: "mishka_pay-usage-" <> _, value: value}} =
               MishkaPay.report_usage(%{
                 provider: "stripe",
                 tenant: "site-a",
                 event_name: "api_call",
                 customer_id: "cus_123",
                 value: "2.5",
                 at: DateTime.add(DateTime.utc_now(), -3600),
                 reference: "request-1"
               })

      assert Decimal.equal?(value, Decimal.new("2.5"))

      from = ~U[2026-11-01 00:00:00Z]

      assert {:ok,
              %MishkaPay.UsageSummary{meter_id: "mtr_123", customer_id: "cus_123", value: 25}} =
               MishkaPay.usage_summary(
                 "stripe",
                 "mtr_123",
                 "cus_123",
                 from,
                 DateTime.add(from, 1, :day),
                 "site-a"
               )

      assert {:ok, %MishkaPay.Price{}} =
               MishkaPay.create_price(%{
                 provider: "stripe",
                 tenant: "site-a",
                 product_id: "prod_123",
                 amount: %{amount: "0.05", currency: "USD"},
                 interval: :month,
                 meter_id: "mtr_123"
               })

      params =
        Stripe.Mapper.price_params(%MishkaPay.Price{
          product_id: "prod_1",
          amount: Money.new(:USD, "0.05"),
          interval: :month,
          meter_id: "mtr_1"
        })

      assert %{"usage_type" => "metered", "meter" => "mtr_1", "interval" => "month"} =
               params["recurring"]

      assert {:ok, %MishkaPay.Price{meter_id: "mtr_9", interval: :month}} =
               Stripe.Mapper.price(%{
                 "id" => "price_1",
                 "currency" => "usd",
                 "unit_amount" => 5,
                 "recurring" => %{
                   "interval" => "month",
                   "usage_type" => "metered",
                   "meter" => "mtr_9"
                 }
               })
    end

    test "a usage report sends its reference as Stripe's identifier and idempotency key, with its value and time" do
      test_pid = self()

      MishkaPay.Test.stub_http(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        send(test_pid, {:sent, params, Plug.Conn.get_req_header(conn, "idempotency-key")})

        Req.Test.json(conn, %{
          "object" => "billing.meter_event",
          "event_name" => params["event_name"],
          "identifier" => params["identifier"],
          "payload" => %{"value" => params["payload[value]"]},
          "timestamp" => 1_794_825_000
        })
      end)

      at = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
      usage = %{provider: "stripe", event_name: "tokens", customer_id: "cus_1", reference: "r-1"}

      assert {:ok, %MishkaPay.Usage{id: identifier}} =
               MishkaPay.report_usage(Map.merge(usage, %{value: 1200, at: at}))

      assert_received {:sent, sent, [^identifier]}

      assert %{
               "event_name" => "tokens",
               "payload[stripe_customer_id]" => "cus_1",
               "payload[value]" => "1200",
               "identifier" => ^identifier
             } = sent

      assert sent["timestamp"] == Integer.to_string(DateTime.to_unix(at))

      assert {:ok, %MishkaPay.Usage{id: ^identifier}} =
               MishkaPay.report_usage(Map.put(usage, :value, Decimal.new("-3.50")))

      assert_received {:sent, %{"payload[value]" => "-3.50"} = again, [^identifier]}
      refute Map.has_key?(again, "timestamp")

      assert {:ok, %MishkaPay.Usage{id: nil, value: 1}} =
               MishkaPay.report_usage(Map.delete(usage, :reference))

      assert_received {:sent, without, [client_key]}
      refute Map.has_key?(without, "identifier")
      refute client_key == identifier
    end

    test "a usage window goes to Stripe in whole minutes, and an empty one counts 0" do
      test_pid = self()

      MishkaPay.Test.stub_http(fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:query, conn.request_path, conn.query_params})
        Req.Test.json(conn, %{"object" => "list", "data" => [], "has_more" => false})
      end)

      from = ~U[2026-11-16 10:00:30Z]
      to = ~U[2026-11-16 11:15:01Z]

      assert {:ok, %MishkaPay.UsageSummary{value: 0, from: start, to: finish}} =
               MishkaPay.usage_summary("stripe", "mtr_1", "cus_1", from, to)

      assert start == ~U[2026-11-16 10:00:00Z]
      assert finish == ~U[2026-11-16 11:16:00Z]

      assert_received {:query, "/v1/billing/meters/mtr_1/event_summaries",
                       %{"customer" => "cus_1", "start_time" => start_time}}

      assert start_time == Integer.to_string(DateTime.to_unix(start))
    end

    test "features are made and attached to a product, and a customer's entitlements listed, as Stripe's spec accepts" do
      assert {:ok, %MishkaPay.Feature{id: "feat_" <> _, lookup_key: "api-access", active: true}} =
               MishkaPay.create_feature(%{
                 provider: "stripe",
                 tenant: "site-a",
                 name: "API access",
                 lookup_key: "api-access"
               })

      assert {:ok, %MishkaPay.Feature{}} =
               MishkaPay.attach_feature("stripe", "prod_123", "feat_123", "site-a")

      assert {:ok,
              %MishkaPay.Page{
                items: [%MishkaPay.Entitlement{id: "ent_" <> _, feature_id: "feat_" <> _}]
              }} = MishkaPay.list_entitlements("stripe", "cus_123", "site-a", limit: 5)
    end

    test "the balance and its transactions, by payout and type, are read as Stripe's spec answers" do
      assert {:ok, %MishkaPay.Balance{available: [%Elixir.Money{}], pending: [%Elixir.Money{}]}} =
               MishkaPay.fetch_balance("stripe", "site-a")

      assert {:ok,
              %MishkaPay.Page{
                items: [
                  %MishkaPay.BalanceTransaction{
                    id: "txn_" <> _,
                    type: "charge",
                    status: :available
                  }
                ]
              }} =
               MishkaPay.list_balance_transactions("stripe", "site-a",
                 payout_id: "po_123",
                 type: "charge",
                 limit: 3
               )
    end

    test "a customer's balance is credited and listed as Stripe's spec accepts" do
      assert {:ok,
              %MishkaPay.CustomerBalanceTransaction{
                id: "cbtxn_" <> _,
                customer_id: "cus_123",
                amount: amount
              }} =
               MishkaPay.adjust_customer_balance(
                 "stripe",
                 "cus_123",
                 %{amount: "-5.00", currency: "USD"},
                 "site-a",
                 description: "Sorry for the outage",
                 reference: "ticket-7"
               )

      assert Money.negative?(amount)

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.CustomerBalanceTransaction{} | _]}} =
               MishkaPay.list_customer_balance("stripe", "cus_123", "site-a", limit: 2)
    end

    test "Stripe's balances keep their sign and currency places, and a credit goes once per reference" do
      test_pid = self()

      MishkaPay.Test.stub_http(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(
          test_pid,
          {:sent, URI.decode_query(body), Plug.Conn.get_req_header(conn, "idempotency-key")}
        )

        Req.Test.json(conn, %{
          "id" => "cbtxn_1",
          "object" => "customer_balance_transaction",
          "amount" => -50_000,
          "currency" => "isk",
          "customer" => "cus_1",
          "ending_balance" => -70_000,
          "type" => "adjustment",
          "metadata" => %{"mishka_pay_reference" => "ticket-7"},
          "created" => 1_794_825_000
        })
      end)

      credit = fn ->
        MishkaPay.adjust_customer_balance("stripe", "cus_1", Money.new(:ISK, "-500"), nil,
          reference: "ticket-7"
        )
      end

      assert {:ok,
              %MishkaPay.CustomerBalanceTransaction{
                amount: amount,
                ending_balance: ending,
                reference: "ticket-7",
                type: "adjustment"
              }} = credit.()

      assert Money.equal?(amount, Money.new(:ISK, "-500"))
      assert Money.equal?(ending, Money.new(:ISK, "-700"))

      assert_received {:sent, %{"amount" => "-50000", "currency" => "isk"}, [key]}
      assert {:ok, _same} = credit.()
      assert_received {:sent, _params, [^key]}

      assert {:ok, %MishkaPay.Balance{available: [usd, jpy], pending: []}} =
               Stripe.Mapper.balance(%{
                 "available" => [
                   %{"amount" => -1250, "currency" => "usd"},
                   %{"amount" => 300, "currency" => "jpy"}
                 ],
                 "pending" => []
               })

      assert Money.equal?(usd, Money.new(:USD, "-12.50"))
      assert Money.equal?(jpy, Money.new(:JPY, 300))

      assert {:ok,
              %MishkaPay.BalanceTransaction{amount: out, fee: fee, net: net, source_id: "po_1"}} =
               Stripe.Mapper.balance_transaction(%{
                 "id" => "txn_1",
                 "amount" => -10_000,
                 "fee" => 25,
                 "net" => -10_025,
                 "currency" => "usd",
                 "source" => "po_1",
                 "type" => "payout",
                 "status" => "pending"
               })

      assert Money.equal?(out, Money.new(:USD, "-100.00"))
      assert Money.equal?(fee, Money.new(:USD, "0.25"))
      assert Money.equal?(net, Money.new(:USD, "-100.25"))
    end

    test "usage, entitlements and balances that cannot be right are refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
      usage = %{provider: "stripe", event_name: "api_call", customer_id: "cus_1"}
      now = DateTime.utc_now()

      for {result, field} <- [
            {MishkaPay.create_meter(%{provider: "stripe", name: "No event"}), :event_name},
            {MishkaPay.create_meter(%{provider: "stripe", event_name: "e", aggregation: :max}),
             :aggregation},
            {MishkaPay.report_usage(Map.put(usage, :value, 1.5)), :value},
            {MishkaPay.report_usage(Map.put(usage, :value, "lots")), :value},
            {MishkaPay.report_usage(Map.put(usage, :customer_id, "cs_1")), :customer_id},
            {MishkaPay.report_usage(Map.put(usage, :at, DateTime.add(now, -36, :day))), :at},
            {MishkaPay.report_usage(Map.put(usage, :at, DateTime.add(now, 10, :minute))), :at},
            {MishkaPay.usage_summary("stripe", "mtr_1", "cus_1", now, now), :to},
            {MishkaPay.usage_summary("stripe", "evt_1", "cus_1", now, DateTime.add(now, 60)),
             :meter_id},
            {MishkaPay.deactivate_meter("stripe", "../charges"), :meter_id},
            {MishkaPay.reactivate_meter("stripe", "mtr_1/../x"), :meter_id},
            {MishkaPay.fetch_fraud_warning("stripe", "prv_1"), :warning_id},
            {MishkaPay.fetch_fraud_review("stripe", "issfr_1"), :review_id},
            {MishkaPay.approve_fraud_review("stripe", "prv_1/../../charges"), :review_id},
            {MishkaPay.list_fraud_warnings("stripe", nil, payment_id: "ch_1"), :payment_id},
            {MishkaPay.list_fraud_warnings("stripe", nil, charge_id: "ch_1&x=y"), :charge_id},
            {MishkaPay.fetch_meter("stripe", "evt_1"), :meter_id},
            {MishkaPay.update_meter(%{provider: "stripe", id: "mtr_1"}), :name},
            {MishkaPay.update_meter(%{provider: "stripe", id: "../x", name: "N"}), :id},
            {MishkaPay.cancel_usage(%{provider: "stripe", event_name: "api_call"}), :usage_id},
            {MishkaPay.cancel_usage(%{provider: "stripe", usage_id: "u1"}), :event_name},
            {MishkaPay.create_price(%{
               provider: "stripe",
               product_id: "prod_1",
               amount: %{amount: "1", currency: "USD"},
               meter_id: "mtr_1"
             }), :interval},
            {MishkaPay.create_price(%{
               provider: "stripe",
               product_id: "prod_1",
               amount: %{amount: "1", currency: "USD"},
               interval: :month,
               meter_id: "evt_1"
             }), :meter_id},
            {MishkaPay.create_feature(%{provider: "stripe", name: "No key"}), :lookup_key},
            {MishkaPay.attach_feature("stripe", "prod_1", "price_1"), :feature_id},
            {MishkaPay.attach_feature("stripe", "../prod", "feat_1"), :product_id},
            {MishkaPay.list_entitlements("stripe", "sub_1"), :customer_id},
            {MishkaPay.list_balance_transactions("stripe", nil, payout_id: "tr_1"), :payout_id},
            {MishkaPay.list_balance_transactions("stripe", nil, type: "a&b"), :type},
            {MishkaPay.adjust_customer_balance("stripe", "cus_1", %{amount: "x", currency: "USD"}),
             :amount},
            {MishkaPay.adjust_customer_balance("stripe", "cus_1", Money.new(:ISK, "-0.5")),
             :amount},
            {MishkaPay.adjust_customer_balance("stripe", "sub_1", Money.new(:USD, 5)),
             :customer_id},
            {MishkaPay.list_customer_balance("stripe", "../cus"), :customer_id}
          ] do
        assert {:error, %Errors.Invalid{errors: errors}} = result
        assert Enum.any?(errors, &(&1.field == field)), inspect({field, errors})
      end
    end

    test "an embedded checkout that holds the money goes to Stripe as its spec accepts" do
      embedded =
        @checkout
        |> Map.drop([:success_url, :cancel_url])
        |> Map.merge(%{
          ui_mode: :embedded,
          return_url: "https://shop.test/return?session_id={CHECKOUT_SESSION_ID}",
          capture: :manual
        })

      assert {:ok, %Checkout{id: "cs_" <> _, ui_mode: :embedded, capture: :manual}} =
               MishkaPay.checkout(embedded)

      params =
        Stripe.Mapper.checkout_params(%{
          params_checkout()
          | ui_mode: :embedded,
            success_url: nil,
            cancel_url: nil,
            return_url: "https://shop.test/return",
            capture: :manual
        })

      assert {params["ui_mode"], params["return_url"]} ==
               {"embedded_page", "https://shop.test/return"}

      refute Map.has_key?(params, "success_url")
      assert params["payment_intent_data"]["capture_method"] == "manual"

      hosted = Stripe.Mapper.checkout_params(params_checkout())
      assert hosted["success_url"] == "https://shop.test/thanks"
      refute Map.has_key?(hosted, "ui_mode")
      refute Map.has_key?(hosted["payment_intent_data"], "capture_method")
    end

    test "a held payment is captured, whole or in part, or let go, as Stripe's spec accepts" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :request, :start]])

      assert {:ok, %Payment{id: "pi_" <> _}} =
               MishkaPay.capture_payment("stripe", "pi_123", "site-a")

      assert_received {_, ^ref, _,
                       %{
                         path: "/v1/payment_intents/pi_123/capture",
                         idempotency_key: "mishka_pay-capture-" <> _ = whole
                       }}

      assert {:ok, %Payment{}} =
               MishkaPay.capture_payment("stripe", "pi_123", "site-a",
                 amount: %{amount: "5", currency: "USD"}
               )

      assert_received {_, ^ref, _,
                       %{path: "/v1/payment_intents/pi_123/capture", idempotency_key: part}}

      refute part == whole

      assert {:ok, %Payment{}} = MishkaPay.cancel_payment("stripe", "pi_123", "site-a")

      assert_received {_, ^ref, _,
                       %{
                         path: "/v1/payment_intents/pi_123/cancel",
                         idempotency_key: "mishka_pay-payment-cancel-" <> _
                       }}

      # Stripe's fixture holds 10.99 USD.
      for {amount, message} <- [
            {%{amount: "5", currency: "EUR"}, "in the payment's currency, USD"},
            {%{amount: "50", currency: "USD"}, "more than the payment holds"}
          ] do
        assert {:error, %Errors.Invalid{errors: [%{field: :amount, message: text}]}} =
                 MishkaPay.capture_payment("stripe", "pi_123", "site-a", amount: amount)

        assert text =~ message
      end
    end

    test "a refund is read again and listed by payment, as Stripe's spec answers" do
      assert {:ok, %Refund{provider: "stripe", id: "re_" <> _, amount: %Elixir.Money{}}} =
               MishkaPay.fetch_refund("stripe", "re_123", "site-a")

      assert {:ok, %MishkaPay.Page{items: [%Refund{} | _]}} =
               MishkaPay.list_refunds("stripe", "site-a", payment_id: "pi_123", limit: 3)

      assert {:error, %Errors.Invalid{errors: [%{field: :refund_id}]}} =
               MishkaPay.fetch_refund("stripe", "pi_123", "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :payment_id}]}} =
               MishkaPay.list_refunds("stripe", "site-a", payment_id: "ch_1")
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

    test "a request stripe-mock refuses keeps the request id it answered with" do
      assert {:error, %Errors.Rejected{status: 400, request_id: "req_" <> _}} =
               MishkaPay.Providers.Stripe.request(
                 :post,
                 "/v1/customers",
                 %{"phone" => %{"a" => "b"}},
                 %MishkaPay.Credentials{provider: "stripe", secret_key: "sk_test_123"}
               )
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
    test "a connected account that is not an account id, or would end the header, is never sent" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)

      MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_1", account_id: "cus_1"}, "site-c")

      assert {:error, %Errors.Invalid{errors: [%{field: :account_id}]}} =
               MishkaPay.fetch_payment("stripe", "pi_123", "site-c")

      for id <- ["acct_1\r\nstripe-account: acct_2", "acct_1 acct_2", ""] do
        MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_1", account_id: id}, "site-c")

        assert {:error, %Errors.Invalid{errors: [%{field: :account_id}]}} =
                 MishkaPay.fetch_payment("stripe", "pi_123", "site-c")
      end
    end

    test "a connected account or link that cannot be right never reaches Stripe" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
      link = %{provider: "stripe", account_id: "acct_1", return_url: "https://shop.test/done"}

      for {call, field} <- [
            {fn -> MishkaPay.fetch_connected_account("stripe", "cus_1") end, :account_id},
            {fn -> MishkaPay.fetch_connected_account("stripe", "acct_1/../../v1/charges") end,
             :account_id},
            {fn -> MishkaPay.update_connected_account(%{provider: "stripe", id: "../x"}) end,
             :id},
            {fn -> MishkaPay.update_connected_account(%{provider: "stripe"}) end, :id},
            {fn -> MishkaPay.login_link("stripe", "acct_1?x=y") end, :account_id},
            {fn ->
               MishkaPay.reject_connected_account("stripe", "acct_1", nil, reason: "boring")
             end, :reason},
            {fn -> MishkaPay.account_link(link) end, :refresh_url},
            {fn ->
               MishkaPay.account_link(Map.put(link, :refresh_url, "http://evil.test/again"))
             end, :refresh_url},
            {fn ->
               MishkaPay.account_link(
                 Map.merge(link, %{refresh_url: "https://shop.test/a", account_id: "ca_1"})
               )
             end, :account_id},
            {fn ->
               MishkaPay.create_connected_account(%{
                 provider: "stripe",
                 capabilities: ["card_payments][x"]
               })
             end, :capabilities},
            {fn -> MishkaPay.create_connected_account(%{provider: "stripe", country: "USA"}) end,
             :country},
            {fn -> MishkaPay.create_connected_account(%{provider: "stripe", type: :platform}) end,
             :type}
          ] do
        assert {:error, %Errors.Invalid{errors: [%{field: ^field} | _]}} = call.()
      end
    end

    test "money for a seller that cannot be right never reaches Stripe" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)

      transfer = %{
        provider: "stripe",
        amount: %{amount: "5.00", currency: "USD"},
        destination: "acct_1",
        reference: "t-1"
      }

      plan = %{
        @checkout
        | items: [%{name: "Pro", amount: %{amount: "10.00", currency: "USD"}, interval: :month}]
      }

      setup = %{
        provider: "stripe",
        mode: :setup,
        currency: "usd",
        success_url: "https://shop.test/ok",
        cancel_url: "https://shop.test/no"
      }

      for {call, field} <- [
            {fn -> MishkaPay.create_transfer(Map.delete(transfer, :reference)) end, :reference},
            {fn -> MishkaPay.create_transfer(%{transfer | destination: "cus_1"}) end,
             :destination},
            {fn ->
               MishkaPay.create_transfer(%{transfer | amount: %{amount: "0", currency: "USD"}})
             end, :amount},
            {fn -> MishkaPay.create_transfer(Map.put(transfer, :source_charge_id, "pi_1")) end,
             :source_charge_id},
            {fn -> MishkaPay.fetch_transfer("stripe", "tr_1/../x") end, :transfer_id},
            {fn -> MishkaPay.reverse_transfer("stripe", "po_1") end, :transfer_id},
            {fn -> MishkaPay.reverse_transfer("stripe", "tr_1", nil, amount: "-1") end, :amount},
            {fn -> MishkaPay.list_transfers("stripe", nil, destination: "cus_1") end,
             :destination},
            {fn -> MishkaPay.fetch_payout("stripe", "tr_1") end, :payout_id},
            {fn -> MishkaPay.cancel_payout("stripe", "po_1?x") end, :payout_id},
            {fn -> MishkaPay.list_payouts("stripe", nil, status: :lost) end, :status},
            {fn -> MishkaPay.fetch_application_fee("stripe", "ch_1") end, :fee_id},
            {fn -> MishkaPay.refund_application_fee("stripe", "fee_1/../x") end, :fee_id},
            {fn -> MishkaPay.list_application_fees("stripe", nil, charge_id: "ch_1&x=y") end,
             :charge_id},
            {fn -> MishkaPay.checkout(Map.put(@checkout, :destination, "cus_1")) end,
             :destination},
            {fn -> MishkaPay.checkout(Map.put(@checkout, :on_behalf_of, "../x")) end,
             :on_behalf_of},
            {fn ->
               MishkaPay.checkout(
                 Map.put(@checkout, :application_fee, %{amount: "1", currency: "EUR"})
               )
             end, :application_fee},
            {fn -> MishkaPay.checkout(Map.put(@checkout, :application_fee_percent, 10)) end,
             :application_fee_percent},
            {fn ->
               MishkaPay.checkout(
                 Map.merge(plan, %{
                   mode: :subscription,
                   application_fee: %{amount: "1", currency: "USD"}
                 })
               )
             end, :application_fee},
            {fn ->
               MishkaPay.checkout(
                 Map.merge(plan, %{mode: :subscription, application_fee_percent: "100.5"})
               )
             end, :application_fee_percent},
            {fn ->
               MishkaPay.checkout(
                 Map.merge(plan, %{mode: :subscription, application_fee_percent: "1.255"})
               )
             end, :application_fee_percent},
            {fn -> MishkaPay.checkout(Map.put(setup, :destination, "acct_1")) end, :destination}
          ] do
        assert {:error, %Errors.Invalid{errors: [%{field: ^field} | _]}} = call.()
      end
    end

    test "a raw call has no way to set a header, so it cannot act for another account" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)

      for extra <- [
            %{headers: %{"stripe-account" => "acct_other"}},
            %{options: %{headers: %{"stripe-account" => "acct_other"}}},
            %{options: %{stripe_account: "acct_other"}}
          ] do
        assert {:error, %Errors.Invalid{}} =
                 MishkaPay.request(
                   Map.merge(%{provider: "stripe", tenant: "site-a", path: "/v1/balance"}, extra)
                 )
      end
    end

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

    test "a currency Stripe counts differently from ISO 4217 goes as Stripe counts it, and a fraction of one is refused" do
      test_pid = self()

      MishkaPay.Test.stub_http(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        send(
          test_pid,
          {:sent, params["line_items[0][price_data][currency]"],
           params["line_items[0][price_data][unit_amount]"]}
        )

        Req.Test.json(conn, %{
          "id" => "cs_1",
          "url" => "https://checkout.stripe.com/c/pay/cs_1",
          "status" => "open",
          "currency" => params["line_items[0][price_data][currency]"],
          "amount_total" => String.to_integer(params["line_items[0][price_data][unit_amount]"])
        })
      end)

      for {currency, amount, sent, read} <- [
            {"ISK", "5", "500", "5"},
            {"UGX", "3000", "300000", "3000"},
            {"MGA", "1000", "1000", "1000"},
            {"HUF", "10.45", "1045", "10.45"},
            {"TWD", "800", "80000", "800"}
          ] do
        item = %{name: "Ebook", amount: %{amount: amount, currency: currency}}

        assert {:ok, %Checkout{amount_total: total}} =
                 MishkaPay.checkout(%{@checkout | items: [item]})

        downcased = String.downcase(currency)
        assert_received {:sent, ^downcased, ^sent}
        assert Elixir.Money.equal?(total, Elixir.Money.new(currency, read))
      end

      mga = %{name: "Ebook", amount: %{amount: "10.50", currency: "MGA"}}

      assert {:error, %Errors.Invalid{errors: [%{field: :amount, message: message}]}} =
               MishkaPay.checkout(%{@checkout | items: [mga]})

      assert message =~ "MGA"
      refute_received {:sent, _currency, _amount}
    end

    test "Stripe's 402 for a card it declined is a decline with Stripe's code" do
      MishkaPay.Test.stub_http(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("request-id", "req_decline1")
        |> Plug.Conn.put_status(402)
        |> Req.Test.json(%{
          "error" => %{
            "type" => "card_error",
            "code" => "card_declined",
            "decline_code" => "insufficient_funds",
            "doc_url" => "https://stripe.com/docs/error-codes/card-declined",
            "message" => "Your card has insufficient funds."
          }
        })
      end)

      assert {:error,
              %Errors.Declined{
                provider: "stripe",
                reason: "insufficient_funds",
                request_id: "req_decline1",
                doc_url: "https://stripe.com/docs/error-codes/card-declined"
              } = error} =
               MishkaPay.refund(%{provider: "stripe", tenant: "site-a", payment_id: "pi_123"})

      assert %Errors.Declined{request_id: "req_decline1"} =
               error |> MishkaPay.Ash.to_ash_error() |> MishkaPay.Ash.provider_error()

      for text <- [Exception.message(error), MishkaPay.Ash.message(error)] do
        refute text =~ "req_decline1"
        refute text =~ "stripe.com/docs"
      end
    end

    test "a refusal keeps Stripe's request id and error page for support, never in its words" do
      MishkaPay.Test.stub_http(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("request-id", "req_refused1")
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{
          "error" => %{
            "type" => "invalid_request_error",
            "code" => "resource_missing",
            "param" => "id",
            "doc_url" => "https://stripe.com/docs/error-codes/resource-missing",
            "message" => "No such payment_intent: 'pi_gone'"
          }
        })
      end)

      assert {:error,
              %Errors.Rejected{
                status: 404,
                code: "resource_missing",
                request_id: "req_refused1",
                doc_url: "https://stripe.com/docs/error-codes/resource-missing"
              } = error} = MishkaPay.fetch_payment("stripe", "pi_gone", "site-a")

      ash_error = error |> MishkaPay.Ash.to_ash_error() |> Ash.Error.to_error_class()

      assert %Errors.Rejected{request_id: "req_refused1"} =
               MishkaPay.Ash.provider_error(ash_error)

      for text <- [
            Exception.message(error),
            MishkaPay.Ash.message(error),
            MishkaPay.Ash.message(ash_error),
            Exception.message(ash_error)
          ] do
        refute text =~ "req_refused1"
        refute text =~ "stripe.com/docs"
      end

      assert MishkaPay.Ash.provider_error(%Errors.Unsupported{}) == nil
    end

    test "a file Stripe would not take, or a file field that holds no file id, is refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
      big = <<0x89, "PNG">> <> :binary.copy(<<0>>, 5_000_000)

      for {attrs, field} <- [
            {%{@upload | content: ""}, :content},
            {%{@upload | content: nil}, :content},
            {%{@upload | content_type: "text/plain", content: "notes"}, :content_type},
            {%{@upload | content_type: "image/gif", content: "GIF89a"}, :content_type},
            {%{@upload | content_type: "image/png", content: big}, :content},
            {%{@upload | content_type: "image/png"}, :content},
            {%{@upload | filename: "../etc/passwd"}, :filename},
            {%{@upload | filename: "a\r\nb.pdf"}, :filename},
            {%{@upload | purpose: :business_logo}, :purpose}
          ] do
        assert {:error, %Errors.Invalid{errors: errors}} = MishkaPay.upload_file(attrs)
        assert Enum.any?(errors, &(&1.field == field)), inspect({field, errors})
      end

      assert {:error, %Errors.Invalid{errors: [%{field: :file_id}]}} =
               MishkaPay.fetch_file("stripe", "file_1/../../v1/charges", "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :file_id}]}} =
               MishkaPay.file_link("stripe", "link_1", "site-a")

      for at <- [DateTime.add(DateTime.utc_now(), -60), "tomorrow"] do
        assert {:error, %Errors.Invalid{errors: [%{field: :expires_at}]}} =
                 MishkaPay.file_link("stripe", "file_1", "site-a", expires_at: at)
      end

      for evidence <- [%{"receipt" => "a receipt in words"}, %{"uncategorized_file" => "cus_1"}] do
        assert {:error, %Errors.Invalid{errors: [%{field: :evidence}]}} =
                 MishkaPay.update_dispute(%{
                   provider: "stripe",
                   dispute_id: "dp_123",
                   evidence: evidence
                 })
      end
    end
  end

  describe "files" do
    test "an upload goes to Stripe's files host as multipart, with its purpose, name and type" do
      test_pid = self()

      MishkaPay.Test.stub_http(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sent, conn.host, conn.request_path, Map.new(conn.req_headers), body})

        Req.Test.json(conn, %{
          "id" => "file_1",
          "object" => "file",
          "purpose" => "dispute_evidence",
          "filename" => "receipt.pdf",
          "size" => byte_size(@upload.content),
          "type" => "pdf",
          "url" => "https://files.stripe.com/v1/files/file_1/contents",
          "created" => 1_780_000_000,
          "expires_at" => 1_803_000_000
        })
      end)

      assert {:ok,
              %MishkaPay.File{
                id: "file_1",
                purpose: :dispute_evidence,
                filename: "receipt.pdf",
                type: "pdf",
                size: size,
                expires_at: %DateTime{}
              }} = MishkaPay.upload_file(@upload)

      assert size == byte_size(@upload.content)
      assert_received {:sent, "files.stripe.com", "/v1/files", headers, body}
      assert "multipart/form-data; boundary=" <> boundary = headers["content-type"]
      assert headers["authorization"] == "Bearer sk_test_123"
      assert headers["stripe-version"] == Stripe.version()
      assert "mp_" <> _ = headers["idempotency-key"]

      assert body ==
               "--#{boundary}\r\ncontent-disposition: form-data; name=\"purpose\"\r\n\r\n" <>
                 "dispute_evidence\r\n" <>
                 "--#{boundary}\r\ncontent-disposition: form-data; name=\"file\"; " <>
                 "filename=\"receipt.pdf\"\r\ncontent-type: application/pdf\r\n\r\n" <>
                 @upload.content <> "\r\n--#{boundary}--\r\n"

      refute inspect(MishkaPay.FileUpload.builder(@upload)) =~ "%PDF"
    end

    test "an upload follows files_url, else base_url, while the API follows base_url only" do
      test_pid = self()
      on_exit(fn -> Application.delete_env(:mishka_pay, Stripe) end)

      MishkaPay.Test.stub_http(fn conn ->
        send(test_pid, {:host, conn.host, conn.port, conn.request_path})
        Req.Test.json(conn, %{"id" => "file_1", "object" => "file", "purpose" => "other"})
      end)

      for {config, files, api} <- [
            {[base_url: "http://localhost:12111"], {"localhost", 12_111}, {"localhost", 12_111}},
            {[base_url: "http://localhost:12111", files_url: "http://files.test:4000"],
             {"files.test", 4000}, {"localhost", 12_111}}
          ] do
        Application.put_env(:mishka_pay, Stripe, config)

        assert {:ok, %MishkaPay.File{purpose: :other}} = MishkaPay.upload_file(@upload)
        assert {:ok, %MishkaPay.File{}} = MishkaPay.fetch_file("stripe", "file_1", "site-a")

        {host, port} = files
        assert_received {:host, ^host, ^port, "/v1/files"}
        {host, port} = api
        assert_received {:host, ^host, ^port, "/v1/files/file_1"}
      end
    end

    test "a link goes to the API with the file and its end, and a dispute takes the file id" do
      test_pid = self()

      MishkaPay.Test.stub_http(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sent, conn.host, conn.request_path, URI.decode_query(body)})

        case conn.request_path do
          "/v1/file_links" ->
            Req.Test.json(conn, %{
              "id" => "link_1",
              "object" => "file_link",
              "file" => "file_1",
              "url" => "https://files.stripe.com/links/abc",
              "expired" => false,
              "expires_at" => 1_790_000_000,
              "created" => 1_780_000_000
            })

          "/v1/disputes/dp_123" ->
            Req.Test.json(conn, %{"id" => "dp_123", "object" => "dispute", "status" => "won"})
        end
      end)

      at = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      unix = Integer.to_string(DateTime.to_unix(at))

      assert {:ok,
              %MishkaPay.FileLink{
                id: "link_1",
                file_id: "file_1",
                url: "https://files.stripe.com/links/abc"
              }} = MishkaPay.file_link("stripe", "file_1", "site-a", expires_at: at)

      assert_received {:sent, "api.stripe.com", "/v1/file_links",
                       %{"file" => "file_1", "expires_at" => ^unix}}

      assert {:ok, %MishkaPay.Dispute{id: "dp_123"}} =
               MishkaPay.update_dispute(%{
                 provider: "stripe",
                 tenant: "site-a",
                 dispute_id: "dp_123",
                 evidence: %{
                   "uncategorized_file" => "file_1",
                   "uncategorized_text" => "The buyer downloaded the file twice."
                 },
                 submit: false
               })

      assert_received {:sent, "api.stripe.com", "/v1/disputes/dp_123",
                       %{
                         "evidence[uncategorized_file]" => "file_1",
                         "evidence[uncategorized_text]" => "The buyer downloaded the file twice."
                       }}
    end
  end

  test "a payment made by a checkout brings the checkout and what it sold" do
    session = %{
      "id" => "cs_1",
      "line_items" => %{
        "data" => [
          %{
            "description" => "LiveView course",
            "quantity" => 2,
            "price" => %{
              "id" => "price_course",
              "product" => "prod_course",
              "unit_amount" => 4900,
              "currency" => "usd"
            }
          },
          %{
            "description" => "Pro plan",
            "quantity" => 1,
            "price" => %{
              "id" => "price_pro",
              "product" => %{"id" => "prod_pro"},
              "unit_amount" => 900,
              "currency" => "usd",
              "recurring" => %{"interval" => "month", "interval_count" => 1}
            }
          }
        ]
      }
    }

    payment = struct(Payment, provider: "stripe", id: "pi_1")

    assert %Payment{checkout_id: "cs_1", items: [course, pro]} =
             Stripe.Mapper.with_checkout(payment, session)

    assert {course.id, course.product_id, course.name, course.quantity} ==
             {"price_course", "prod_course", "LiveView course", 2}

    assert Elixir.Money.equal?(course.amount, Elixir.Money.new(:USD, "49.00"))
    assert {pro.product_id, pro.interval} == {"prod_pro", :month}
    assert %Payment{checkout_id: nil, items: []} = Stripe.Mapper.with_checkout(payment, nil)
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

  test "a schedule maps with its phases, the one running now, and the subscription it let go" do
    schedule = %{
      "object" => "subscription_schedule",
      "id" => "sub_sched_1",
      "customer" => %{"id" => "cus_1", "object" => "customer"},
      "subscription" => nil,
      "released_subscription" => "sub_1",
      "status" => "released",
      "end_behavior" => "release",
      "current_phase" => %{"start_date" => 1_794_000_000, "end_date" => 1_796_600_000},
      "created" => 1_793_000_000,
      "released_at" => 1_795_000_000,
      "metadata" => %{"mishka_pay_reference" => "member-1"},
      "phases" => [
        %{
          "start_date" => 1_791_000_000,
          "end_date" => 1_794_000_000,
          "trial_end" => 1_794_000_000,
          "proration_behavior" => "create_prorations",
          "items" => [%{"price" => "price_intro", "quantity" => 1}]
        },
        %{
          "start_date" => 1_794_000_000,
          "end_date" => 1_796_600_000,
          "proration_behavior" => "none",
          "items" => [%{"price" => %{"id" => "price_full", "object" => "price"}, "quantity" => 3}]
        }
      ]
    }

    assert {:ok, %MishkaPay.SubscriptionSchedule{} = mapped} =
             Stripe.Mapper.subscription_schedule(schedule)

    assert {mapped.id, mapped.customer_id, mapped.subscription_id,
            mapped.released_subscription_id} ==
             {"sub_sched_1", "cus_1", nil, "sub_1"}

    assert {mapped.status, mapped.end_behavior, mapped.current_phase, mapped.reference} ==
             {:released, :release, 1, "member-1"}

    assert [
             %MishkaPay.SubscriptionPhase{
               trial_end_at: %DateTime{},
               items: [%{id: "price_intro"}]
             },
             %MishkaPay.SubscriptionPhase{
               proration: :none,
               items: [%{id: "price_full", quantity: 3}]
             }
           ] = mapped.phases

    assert {:ok, %Subscription{schedule_id: "sub_sched_1"}} =
             Stripe.Mapper.subscription(%{
               "id" => "sub_1",
               "status" => "active",
               "schedule" => "sub_sched_1"
             })

    assert {:ok, %MishkaPay.Event{subscription_id: "sub_1", object_type: "subscription_schedule"}} =
             Stripe.Mapper.event(%{
               "id" => "evt_1",
               "type" => "subscription_schedule.released",
               "data" => %{"object" => schedule}
             })
  end

  test "a credit note maps with its lines, refunds, tax and reference" do
    note = %{
      "object" => "credit_note",
      "id" => "cn_1",
      "invoice" => "in_1",
      "customer" => "cus_1",
      "currency" => "usd",
      "amount" => 1_210,
      "total_taxes" => [%{"amount" => 210}],
      "out_of_band_amount" => nil,
      "memo" => "",
      "number" => "ABCD-0001-CN-01",
      "status" => "void",
      "type" => "post_payment",
      "reason" => "order_change",
      "pdf" => "https://pay.stripe.com/credit_notes/cn_1/pdf",
      "refunds" => [%{"refund" => "re_1", "amount_refunded" => 1_210}, %{"refund" => nil}],
      "voided_at" => 1_794_000_100,
      "created" => 1_794_000_000,
      "metadata" => %{"mishka_pay_reference" => "credit-1", "team" => "ops"},
      "lines" => %{
        "data" => [
          %{
            "id" => "cnli_1",
            "type" => "invoice_line_item",
            "invoice_line_item" => "il_1",
            "quantity" => 1,
            "amount" => 1_000,
            "unit_amount_decimal" => nil
          },
          %{
            "id" => "cnli_2",
            "type" => "custom_line_item",
            "description" => "Goodwill",
            "quantity" => 2,
            "amount" => 0,
            "unit_amount_decimal" => "0"
          }
        ]
      }
    }

    assert {:ok, %MishkaPay.CreditNote{} = mapped} = Stripe.Mapper.credit_note(note)

    assert {mapped.id, mapped.invoice_id, mapped.customer_id, mapped.number} ==
             {"cn_1", "in_1", "cus_1", "ABCD-0001-CN-01"}

    assert {mapped.status, mapped.type, mapped.reason, mapped.memo} ==
             {:void, :post_payment, :order_change, nil}

    assert {mapped.amount, mapped.amount_tax} ==
             {Money.new(:USD, "12.10"), Money.new(:USD, "2.10")}

    assert {mapped.refund_ids, mapped.reference} == {["re_1"], "credit-1"}
    assert mapped.metadata == %{"team" => "ops"}
    assert mapped.voided_at == DateTime.from_unix!(1_794_000_100)

    assert [
             %MishkaPay.CreditNoteLine{
               type: :invoice_line,
               invoice_line_id: "il_1",
               amount: line
             },
             %MishkaPay.CreditNoteLine{type: :custom, name: "Goodwill", quantity: 2}
           ] = mapped.lines

    assert line == Money.new(:USD, "10.00")
  end

  test "a payment and a setup intent map from Stripe's answers, with why the last try failed" do
    assert {:ok,
            %MishkaPay.PaymentIntent{
              id: "pi_1",
              amount: amount,
              amount_received: received,
              capture: :manual,
              setup_future_usage: :off_session,
              status: :requires_payment_method,
              client_secret: "pi_1_secret_x",
              failure_code: "insufficient_funds",
              failure_message: "Your card has insufficient funds.",
              reference: "order-9",
              owner: "user-1",
              metadata: %{"team" => "ops"},
              customer_id: "cus_1",
              payment_method_id: nil
            }} =
             Stripe.Mapper.payment_intent(%{
               "object" => "payment_intent",
               "id" => "pi_1",
               "amount" => 1999,
               "amount_received" => 0,
               "currency" => "eur",
               "capture_method" => "manual",
               "setup_future_usage" => "off_session",
               "status" => "requires_payment_method",
               "client_secret" => "pi_1_secret_x",
               "customer" => %{"id" => "cus_1", "object" => "customer"},
               "last_payment_error" => %{
                 "code" => "card_declined",
                 "decline_code" => "insufficient_funds",
                 "message" => "Your card has insufficient funds."
               },
               "metadata" => %{
                 "mishka_pay_reference" => "order-9",
                 "mishka_pay_owner" => "user-1",
                 "team" => "ops"
               },
               "created" => 1_794_825_000
             })

    assert Money.equal?(amount, Money.new(:EUR, "19.99"))
    assert Money.equal?(received, Money.new(:EUR, 0))

    assert {:ok, %MishkaPay.PaymentIntent{capture: :automatic, status: :succeeded}} =
             Stripe.Mapper.payment_intent(%{
               "id" => "pi_2",
               "amount" => 500,
               "currency" => "usd",
               "capture_method" => "automatic_async",
               "status" => "succeeded"
             })

    assert {:ok,
            %MishkaPay.SetupIntent{
              id: "seti_1",
              usage: :off_session,
              status: :succeeded,
              payment_method_id: "pm_1"
            }} =
             Stripe.Mapper.setup_intent(%{
               "object" => "setup_intent",
               "id" => "seti_1",
               "usage" => "off_session",
               "status" => "succeeded",
               "payment_method" => "pm_1"
             })

    assert Stripe.Mapper.payment_intent_params(%MishkaPay.PaymentIntent{
             provider: "stripe",
             id: "pi_1",
             description: "New"
           }) == %{"description" => "New"}
  end

  test "a tax rate, a registration and the tax settings map from Stripe's answers" do
    assert {:ok,
            %MishkaPay.TaxRate{
              id: "txr_1",
              percentage: percentage,
              effective_percentage: nil,
              inclusive: true,
              active: false,
              country: "DE",
              state: nil,
              tax_type: "vat",
              reference: "de-vat",
              metadata: %{"team" => "eu"}
            }} =
             Stripe.Mapper.tax_rate(%{
               "object" => "tax_rate",
               "id" => "txr_1",
               "display_name" => "VAT",
               "percentage" => 7.25,
               "effective_percentage" => nil,
               "inclusive" => true,
               "active" => false,
               "country" => "DE",
               "state" => "",
               "tax_type" => "vat",
               "metadata" => %{"mishka_pay_reference" => "de-vat", "team" => "eu"},
               "created" => 1_794_825_000
             })

    assert Decimal.equal?(percentage, Decimal.new("7.25"))

    assert {:ok,
            %MishkaPay.TaxRegistration{country: "CA", type: "province_standard", state: "BC"}} =
             Stripe.Mapper.tax_registration(%{
               "id" => "taxreg_1",
               "country" => "CA",
               "country_options" => %{
                 "ca" => %{
                   "type" => "province_standard",
                   "province_standard" => %{"province" => "BC"}
                 }
               },
               "status" => "scheduled",
               "active_from" => 1_894_825_000
             })

    for {country, scheme, read} <- [
          {"DE", "small_seller", :small_seller},
          {"DE", "inbound_goods", :inbound_goods},
          {"GB", "inbound_goods", :inbound_goods},
          {"JP", "standard", :standard},
          {"GB", "something_new", nil}
        ] do
      assert {:ok,
              %MishkaPay.TaxRegistration{
                country: ^country,
                type: "standard",
                place_of_supply_scheme: ^read
              }} =
               Stripe.Mapper.tax_registration(%{
                 "id" => "taxreg_2",
                 "country" => country,
                 "country_options" => %{
                   String.downcase(country) => %{
                     "type" => "standard",
                     "standard" => %{"place_of_supply_scheme" => scheme}
                   }
                 },
                 "status" => "active"
               })
    end

    assert {:ok, %MishkaPay.TaxSettings{status: :pending, missing_fields: ["head_office"]} = none} =
             Stripe.Mapper.tax_settings(%{
               "object" => "tax.settings",
               "defaults" => %{"tax_behavior" => "inferred_by_currency", "tax_code" => nil},
               "head_office" => nil,
               "status" => "pending",
               "status_details" => %{"pending" => %{"missing_fields" => ["head_office"]}}
             })

    assert {none.head_office, none.tax_behavior} == {nil, :inferred_by_currency}

    rate = %MishkaPay.TaxRate{provider: "stripe", id: "txr_1", percentage: Decimal.new(5)}
    assert Stripe.Mapper.tax_rate_params(rate) == %{}

    assert {:ok, %MishkaPay.InvoiceItem{tax_rate_ids: ["txr_1"]}} =
             Stripe.Mapper.invoice_item(%{
               "object" => "invoiceitem",
               "id" => "ii_1",
               "currency" => "usd",
               "amount" => 1000,
               "tax_rates" => [%{"object" => "tax_rate", "id" => "txr_1"}]
             })
  end

  test "an invoice item maps with its price of one, its total, its bill and its reference" do
    item = %{
      "object" => "invoiceitem",
      "id" => "ii_1",
      "customer" => "cus_1",
      "invoice" => nil,
      "currency" => "usd",
      "amount" => 9_800,
      "quantity" => 2,
      "description" => "Setup fee",
      "date" => 1_794_000_000,
      "period" => %{"start" => 1_794_000_000, "end" => 1_794_000_000},
      "pricing" => %{
        "type" => "price_details",
        "price_details" => %{"price" => "price_1", "product" => "prod_1"},
        "unit_amount_decimal" => "4900"
      },
      "metadata" => %{"mishka_pay_reference" => "setup-1", "team" => "ops"}
    }

    assert {:ok, %MishkaPay.InvoiceItem{} = mapped} = Stripe.Mapper.invoice_item(item)

    assert {mapped.id, mapped.customer_id, mapped.invoice_id, mapped.price_id, mapped.name} ==
             {"ii_1", "cus_1", nil, "price_1", "Setup fee"}

    assert {mapped.amount, mapped.total, mapped.quantity} ==
             {Money.new(:USD, "49.00"), Money.new(:USD, "98.00"), 2}

    assert {mapped.reference, mapped.metadata} == {"setup-1", %{"team" => "ops"}}
    assert mapped.created_at == DateTime.from_unix!(1_794_000_000)

    assert {:ok, %MishkaPay.InvoiceItem{total: credit, amount: nil, invoice_id: "in_1"}} =
             item
             |> Map.merge(%{"amount" => -500, "invoice" => "in_1", "quantity" => 1})
             |> put_in(["pricing", "unit_amount_decimal"], "-499.5")
             |> Stripe.Mapper.invoice_item()

    assert credit == Money.new(:USD, "-5.00")
  end

  test "a portal configuration maps each feature: on with its choices, or off" do
    config = %{
      "object" => "billing_portal.configuration",
      "id" => "bpc_1",
      "name" => "Teams",
      "active" => true,
      "is_default" => false,
      "created" => 1_794_000_000,
      "default_return_url" => nil,
      "business_profile" => %{"headline" => "Billing", "privacy_policy_url" => nil},
      "metadata" => %{},
      "features" => %{
        "customer_update" => %{"enabled" => true, "allowed_updates" => ["email", "tax_id"]},
        "invoice_history" => %{"enabled" => true},
        "payment_method_update" => %{"enabled" => false},
        "subscription_cancel" => %{"enabled" => true, "mode" => "at_period_end"},
        "subscription_update" => %{
          "enabled" => true,
          "default_allowed_updates" => ["price"],
          "products" => [%{"product" => "prod_1", "prices" => ["price_a"]}],
          "proration_behavior" => "create_prorations"
        }
      }
    }

    assert {:ok, %MishkaPay.PortalConfiguration{} = mapped} =
             Stripe.Mapper.portal_configuration(config)

    assert {mapped.id, mapped.name, mapped.active, mapped.default, mapped.headline} ==
             {"bpc_1", "Teams", true, false, "Billing"}

    assert {mapped.invoice_history, mapped.payment_method_update} == {true, false}
    assert mapped.customer_update == [:email, :tax_id]
    assert {mapped.subscription_cancel, mapped.subscription_update} == {:at_period_end, [:price]}
    assert [%MishkaPay.PortalPlan{product_id: "prod_1", price_ids: ["price_a"]}] = mapped.plans
    assert mapped.proration == :create_prorations

    off =
      config
      |> put_in(["features", "subscription_cancel", "enabled"], false)
      |> put_in(["features", "customer_update", "enabled"], false)

    assert {:ok, %{subscription_cancel: :off, customer_update: []}} =
             Stripe.Mapper.portal_configuration(off)
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

  test "a tax id maps with its country and its register check, and an unchecked kind has none" do
    assert {:ok,
            %MishkaPay.TaxId{
              id: "txi_1",
              customer_id: "cus_1",
              type: "eu_vat",
              value: "DE123456789",
              country: "DE",
              verification: :verified,
              verified_name: "Muster GmbH",
              verified_address: nil,
              created_at: %DateTime{}
            }} =
             Stripe.Mapper.tax_id(%{
               "id" => "txi_1",
               "object" => "tax_id",
               "country" => "DE",
               "created" => 1_679_431_857,
               "customer" => "cus_1",
               "livemode" => false,
               "type" => "eu_vat",
               "value" => "DE123456789",
               "verification" => %{
                 "status" => "verified",
                 "verified_address" => "",
                 "verified_name" => "Muster GmbH"
               }
             })

    assert {:ok, %MishkaPay.TaxId{type: "us_ein", verification: nil}} =
             Stripe.Mapper.tax_id(%{
               "id" => "txi_2",
               "object" => "tax_id",
               "country" => "US",
               "customer" => %{"id" => "cus_1", "object" => "customer"},
               "type" => "us_ein",
               "value" => "12-3456789",
               "verification" => nil
             })
  end

  test "a checkout read back brings where it ships, the chosen rate and what shipping cost" do
    assert %Checkout{
             shipping_address: %MishkaPay.Address{
               name: "Jenny Rosen",
               country: "NL",
               city: "Amsterdam",
               postal_code: "1012 AB",
               line1: "Dam 1",
               line2: nil
             },
             shipping_rate_id: "shr_1",
             amount_shipping: shipping
           } =
             Stripe.Mapper.checkout(%{
               "id" => "cs_1",
               "status" => "complete",
               "currency" => "eur",
               "amount_total" => 2495,
               "collected_information" => %{
                 "business_name" => nil,
                 "individual_name" => nil,
                 "shipping_details" => %{
                   "name" => "Jenny Rosen",
                   "address" => %{
                     "city" => "Amsterdam",
                     "country" => "NL",
                     "line1" => "Dam 1",
                     "line2" => "",
                     "postal_code" => "1012 AB",
                     "state" => nil
                   }
                 }
               },
               "shipping_cost" => %{
                 "amount_subtotal" => 495,
                 "amount_tax" => 0,
                 "amount_total" => 495,
                 "shipping_rate" => "shr_1"
               },
               "total_details" => %{
                 "amount_discount" => 0,
                 "amount_shipping" => 495,
                 "amount_tax" => 0
               }
             })

    assert Money.equal?(shipping, Money.new(:EUR, "4.95"))

    assert %Checkout{shipping_address: nil, shipping_rate_id: nil} =
             Stripe.Mapper.checkout(%{"id" => "cs_2", "collected_information" => nil})

    assert {:ok,
            %MishkaPay.ShippingRate{
              id: "shr_1",
              name: "Express",
              min_days: 1,
              max_days: nil,
              tax_code: "txcd_92010001",
              tax_behavior: :exclusive,
              active: true,
              amount: amount
            }} =
             Stripe.Mapper.shipping_rate(%{
               "id" => "shr_1",
               "object" => "shipping_rate",
               "active" => true,
               "created" => 1_794_000_000,
               "delivery_estimate" => %{
                 "minimum" => %{"unit" => "business_day", "value" => 1},
                 "maximum" => %{"unit" => "week", "value" => 1}
               },
               "display_name" => "Express",
               "fixed_amount" => %{"amount" => 990, "currency" => "usd"},
               "metadata" => %{},
               "tax_behavior" => "exclusive",
               "tax_code" => "txcd_92010001",
               "type" => "fixed_amount"
             })

    assert Money.equal?(amount, Money.new(:USD, "9.90"))
  end

  test "a tax calculation maps with its totals, each line's tax, the address and the expiry" do
    assert {:ok,
            %MishkaPay.TaxCalculation{
              provider: "stripe",
              id: "taxcalc_1",
              address: %MishkaPay.Address{country: "US", state: "WA", postal_code: "98104"},
              address_source: :shipping,
              items: [
                %MishkaPay.TaxLine{
                  id: "tax_li_1",
                  reference: "Music Streaming Coupon",
                  quantity: 1,
                  tax_code: "txcd_10000000",
                  tax_behavior: :exclusive,
                  amount: amount,
                  amount_tax: line_tax
                }
              ],
              amount_total: total,
              tax_amount_exclusive: tax,
              tax_amount_inclusive: inclusive,
              shipping: shipping,
              expires_at: %DateTime{}
            }} =
             Stripe.Mapper.tax_calculation(%{
               "id" => "taxcalc_1",
               "object" => "tax.calculation",
               "amount_total" => 1953,
               "currency" => "usd",
               "customer" => nil,
               "customer_details" => %{
                 "address" => %{
                   "city" => "Seattle",
                   "country" => "US",
                   "line1" => "920 5th Ave",
                   "line2" => nil,
                   "postal_code" => "98104",
                   "state" => "WA"
                 },
                 "address_source" => "shipping",
                 "ip_address" => nil,
                 "tax_ids" => [],
                 "taxability_override" => "none"
               },
               "expires_at" => 1_706_708_005,
               "line_items" => %{
                 "object" => "list",
                 "data" => [
                   %{
                     "id" => "tax_li_1",
                     "object" => "tax.calculation_line_item",
                     "amount" => 1499,
                     "amount_tax" => 154,
                     "product" => nil,
                     "quantity" => 1,
                     "reference" => "Music Streaming Coupon",
                     "tax_behavior" => "exclusive",
                     "tax_code" => "txcd_10000000"
                   }
                 ],
                 "has_more" => false
               },
               "shipping_cost" => %{
                 "amount" => 300,
                 "amount_tax" => 0,
                 "tax_behavior" => "exclusive",
                 "tax_code" => "txcd_92010001"
               },
               "tax_amount_exclusive" => 154,
               "tax_amount_inclusive" => 0,
               "tax_date" => 1_706_535_204
             })

    for {money, expected} <- [
          {amount, "14.99"},
          {line_tax, "1.54"},
          {total, "19.53"},
          {tax, "1.54"},
          {inclusive, "0"},
          {shipping, "3.00"}
        ] do
      assert Money.equal?(money, Money.new(:USD, expected)), inspect({money, expected})
    end

    assert {:ok,
            %MishkaPay.TaxTransaction{
              id: "tax_1",
              reference: "myOrder_123",
              calculation_id: "taxcalc_1",
              posted_at: %DateTime{}
            }} =
             Stripe.Mapper.tax_transaction(
               %{
                 "id" => "tax_1",
                 "object" => "tax.transaction",
                 "created" => 1_690_938_353,
                 "currency" => "usd",
                 "customer" => nil,
                 "posted_at" => 1_690_932_566,
                 "reference" => "myOrder_123",
                 "type" => "transaction"
               },
               "taxcalc_1"
             )
  end

  test "a checkout read back brings its totals and the buyer's email" do
    checkout =
      Stripe.Mapper.checkout(%{
        "id" => "cs_1",
        "status" => "complete",
        "currency" => "usd",
        "amount_total" => 2139,
        "total_details" => %{"amount_tax" => 140},
        "customer_details" => %{"email" => "ava@example.com", "phone" => "+31612345678"},
        "payment_intent" => "pi_1",
        "client_reference_id" => "ebook-1",
        "consent" => %{"terms_of_service" => "accepted"},
        "custom_fields" => [
          %{"key" => "certname", "type" => "text", "text" => %{"value" => "Ava Martin"}},
          %{"key" => "seat", "type" => "dropdown", "dropdown" => %{"value" => "b"}}
        ]
      })

    assert checkout.phone_number == "+31612345678"
    assert checkout.terms_accepted
    assert checkout.field_values == %{"certname" => "Ava Martin", "seat" => "b"}

    assert checkout.amount_total == Money.new(:USD, "21.39")
    assert checkout.amount_tax == Money.new(:USD, "1.40")
    assert checkout.customer.email == "ava@example.com"
    assert {checkout.payment_id, checkout.reference} == {"pi_1", "ebook-1"}
  end

  test "a setup checkout read back brings its setup, the saved payment method and the customer" do
    checkout =
      Stripe.Mapper.checkout(%{
        "id" => "cs_1",
        "object" => "checkout.session",
        "mode" => "setup",
        "status" => "complete",
        "currency" => "usd",
        "amount_total" => nil,
        "customer" => "cus_1",
        "customer_details" => %{"email" => "ava@example.com"},
        "payment_intent" => nil,
        "client_reference_id" => "card-1",
        "setup_intent" => %{
          "id" => "seti_1",
          "object" => "setup_intent",
          "customer" => "cus_1",
          "payment_method" => "pm_1",
          "status" => "succeeded"
        }
      })

    assert {checkout.setup_intent_id, checkout.payment_method_id, checkout.payment_id} ==
             {"seti_1", "pm_1", nil}

    assert {checkout.customer.id, checkout.customer.email} == {"cus_1", "ava@example.com"}

    open = Stripe.Mapper.checkout(%{"id" => "cs_2", "status" => "open", "setup_intent" => nil})
    assert {open.setup_intent_id, open.payment_method_id, open.customer} == {nil, nil, nil}
  end

  test "a payment method maps with its card, and one of another kind without" do
    assert {:ok,
            %MishkaPay.PaymentMethod{
              provider: "stripe",
              id: "pm_1",
              customer_id: "cus_1",
              type: "card",
              card_brand: "visa",
              card_last4: "4242",
              card_exp_month: 12,
              card_exp_year: 2034,
              created_at: %DateTime{}
            }} =
             Stripe.Mapper.payment_method(%{
               "id" => "pm_1",
               "object" => "payment_method",
               "type" => "card",
               "customer" => "cus_1",
               "created" => 1_689_682_128,
               "card" => %{
                 "brand" => "visa",
                 "last4" => "4242",
                 "exp_month" => 12,
                 "exp_year" => 2034,
                 "funding" => "credit"
               }
             })

    assert {:ok, %MishkaPay.PaymentMethod{type: "sepa_debit", customer_id: nil, card_last4: nil}} =
             Stripe.Mapper.payment_method(%{
               "id" => "pm_2",
               "object" => "payment_method",
               "type" => "sepa_debit",
               "customer" => nil,
               "sepa_debit" => %{"last4" => "3000"}
             })
  end

  test "a detached payment method names the customer it left, and one with no customer itself" do
    detached = %{
      "id" => "evt_1",
      "type" => "payment_method.detached",
      "data" => %{
        "object" => %{"id" => "pm_1", "object" => "payment_method", "customer" => nil},
        "previous_attributes" => %{"customer" => "cus_1"}
      }
    }

    assert {:ok,
            %MishkaPay.Event{
              object_type: "payment_method",
              object_id: "pm_1",
              customer_id: "cus_1"
            }} =
             Stripe.Mapper.event(detached)

    alone = %{
      "id" => "evt_2",
      "type" => "setup_intent.setup_failed",
      "data" => %{"object" => %{"id" => "seti_1", "object" => "setup_intent", "customer" => nil}}
    }

    assert {:ok,
            %MishkaPay.Event{object_type: "setup_intent", object_id: "seti_1", customer_id: nil}} =
             Stripe.Mapper.event(alone)
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

  # One object of each kind Stripe sends in a handled event, as its API version names them.
  @objects %{
    "checkout.session" => %{
      "object" => "checkout.session",
      "id" => "cs_1",
      "payment_intent" => "pi_1",
      "subscription" => "sub_1"
    },
    "payment_intent" => %{"object" => "payment_intent", "id" => "pi_1"},
    "charge" => %{"object" => "charge", "id" => "ch_1", "payment_intent" => "pi_1"},
    "refund" => %{"object" => "refund", "id" => "re_1", "payment_intent" => "pi_1"},
    "charge.dispute" => %{"object" => "dispute", "id" => "dp_1", "payment_intent" => "pi_1"},
    "invoice" => %{
      "object" => "invoice",
      "id" => "in_1",
      "parent" => %{"subscription_details" => %{"subscription" => "sub_1"}}
    },
    "invoice_payment" => %{
      "object" => "invoice_payment",
      "id" => "inpay_1",
      "payment" => %{"type" => "payment_intent", "payment_intent" => "pi_1"}
    },
    "customer.subscription" => %{"object" => "subscription", "id" => "sub_1"},
    "customer" => %{"object" => "customer", "id" => "cus_1"},
    "product" => %{"object" => "product", "id" => "prod_1"},
    "price" => %{"object" => "price", "id" => "price_1"},
    "coupon" => %{"object" => "coupon", "id" => "coupon_1"},
    "promotion_code" => %{"object" => "promotion_code", "id" => "promo_1"},
    "payment_link" => %{"object" => "payment_link", "id" => "plink_1"},
    "payment_method" => %{"object" => "payment_method", "id" => "pm_1", "customer" => "cus_1"},
    "setup_intent" => %{"object" => "setup_intent", "id" => "seti_1", "customer" => "cus_1"},
    "entitlements.active_entitlement_summary" => %{
      "object" => "entitlements.active_entitlement_summary",
      "customer" => "cus_1",
      "entitlements" => %{"object" => "list", "data" => []}
    },
    "customer.tax_id" => %{"object" => "tax_id", "id" => "txi_1", "customer" => "cus_1"},
    "subscription_schedule" => %{
      "object" => "subscription_schedule",
      "id" => "sub_sched_1",
      "subscription" => "sub_1",
      "customer" => "cus_1"
    },
    "credit_note" => %{
      "object" => "credit_note",
      "id" => "cn_1",
      "invoice" => "in_1",
      "customer" => "cus_1"
    },
    "radar.early_fraud_warning" => %{
      "object" => "radar.early_fraud_warning",
      "id" => "issfr_1",
      "charge" => "ch_1",
      "payment_intent" => "pi_1"
    },
    "review" => %{
      "object" => "review",
      "id" => "prv_1",
      "charge" => "ch_1",
      "payment_intent" => "pi_1"
    },
    "tax_rate" => %{"object" => "tax_rate", "id" => "txr_1"},
    "account" => %{"object" => "account", "id" => "acct_1"},
    "account.application" => %{"object" => "application", "id" => "ca_1"},
    "transfer" => %{"object" => "transfer", "id" => "tr_1", "destination" => "acct_1"},
    "payout" => %{"object" => "payout", "id" => "po_1"},
    "application_fee" => %{"object" => "application_fee", "id" => "fee_1", "charge" => "ch_1"},
    "application_fee.refund" => %{"object" => "fee_refund", "id" => "fr_1", "fee" => "fee_1"}
  }

  test "every Stripe event Mishka Pay claims to handle names what it updates" do
    for {type, updates} <- Stripe.handled_events() do
      kind = type |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")
      object = Map.fetch!(@objects, kind)

      assert {:ok, event} =
               Stripe.Mapper.event(%{
                 "id" => "evt_1",
                 "type" => type,
                 "created" => 1_794_825_000,
                 "data" => %{"object" => object}
               }),
             type

      for update <- updates do
        assert named?(event, update), "#{type} does not name its #{update}"
      end
    end

    # The bill a renewal will make has no id yet, and still names its subscription.
    upcoming = %{
      "object" => "invoice",
      "id" => nil,
      "parent" => %{"subscription_details" => %{"subscription" => "sub_1"}}
    }

    assert {:ok, %{subscription_id: "sub_1", object_id: nil}} =
             Stripe.Mapper.event(%{
               "id" => "evt_2",
               "type" => "invoice.upcoming",
               "data" => %{"object" => upcoming}
             })
  end

  defp named?(event, :payment), do: event.payment_id == "pi_1"
  defp named?(event, :subscription), do: event.subscription_id == "sub_1"
  defp named?(event, :dispute), do: event.dispute_id == "dp_1"
  defp named?(event, :customer), do: event.customer_id == "cus_1"

  defp named?(event, :fraud_warning),
    do: {event.object_type, event.object_id} == {"radar.early_fraud_warning", "issfr_1"}

  defp named?(event, :fraud_review),
    do: {event.object_type, event.object_id} == {"review", "prv_1"}

  # An account's own change, or the platform it left (an `application`); the event's `account`
  # names it at Stripe.
  defp named?(event, :account),
    do: event.object_type in ["account", "application"] and is_binary(event.object_id)

  # A fee's own change, or a refund of it.
  defp named?(event, :application_fee),
    do: event.object_type in ["application_fee", "fee_refund"] and is_binary(event.object_id)

  defp named?(event, kind),
    do: event.object_type == Atom.to_string(kind) and is_binary(event.object_id)

  # Stripe's answers for a transfer, a reversal of one (its transfer expanded) and an application
  # fee refund (its fee expanded), in euros.
  defp answer_for("/v1/transfers"), do: stripe_transfer(0)

  defp answer_for("/v1/transfers/" <> _reversal),
    do: %{"object" => "transfer_reversal", "id" => "trr_1", "transfer" => stripe_transfer(1100)}

  defp answer_for("/v1/application_fees/" <> _refund),
    do: %{
      "object" => "fee_refund",
      "id" => "fr_1",
      "fee" => %{
        "object" => "application_fee",
        "id" => "fee_1",
        "amount" => 100,
        "amount_refunded" => 50,
        "refunded" => false,
        "currency" => "eur",
        "account" => "acct_1",
        "charge" => "ch_1"
      }
    }

  defp stripe_transfer(reversed),
    do: %{
      "object" => "transfer",
      "id" => "tr_1",
      "amount" => 1100,
      "amount_reversed" => reversed,
      "reversed" => reversed == 1100,
      "currency" => "eur",
      "destination" => "acct_1",
      "metadata" => %{"mishka_pay_reference" => "order-7"}
    }

  test "a capture or a release that cannot be right is refused before any request" do
    MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)

    for amount <- [
          %{amount: "0", currency: "USD"},
          "five",
          %{amount: "5", currency: "XYZ"},
          %{amount: "1.5", currency: "ISK"}
        ] do
      assert {:error, %Errors.Invalid{errors: [%{field: :amount}]}} =
               MishkaPay.capture_payment("stripe", "pi_123", nil, amount: amount)
    end

    assert {:error, %Errors.Invalid{errors: [%{field: :payment_id}]}} =
             MishkaPay.capture_payment("stripe", "ch_123")

    assert {:error, %Errors.Invalid{errors: [%{field: :payment_id}]}} =
             MishkaPay.cancel_payment("stripe", "cs_123")

    # Stripe makes an invoice after payment with `invoice: true` and as the merchant of record,
    # and holds no money then.
    held = Map.put(@checkout, :capture, :manual)

    for attrs <- [Map.put(held, :invoice, true), Map.put(held, :merchant_of_record, true)] do
      assert {:error, %Errors.Invalid{errors: [%{field: :capture}]}} = MishkaPay.checkout(attrs)
    end
  end

  test "Stripe's refusal to hold the money where it invoices names the capture choice" do
    MishkaPay.Test.stub_http(fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "error" => %{
          "type" => "invalid_request_error",
          "message" =>
            "Post-payment invoice creation does not support separate authorization and capture. Please set payment_intent_data[capture_method] to `automatic`."
        }
      })
    end)

    assert {:error, %Errors.Rejected{code: "capture_invoice", param: "capture"} = error} =
             MishkaPay.checkout(Map.put(@checkout, :capture, :manual))

    assert Exception.message(error) =~ "merchant of record"
  end

  test "an embedded Checkout Session reads back with its client secret and return page" do
    session = %{
      "id" => "cs_test_a1",
      "object" => "checkout.session",
      "ui_mode" => "embedded_page",
      "url" => nil,
      "client_secret" => "cs_test_a1_secret_xyz",
      "return_url" => "https://shop.test/return?session_id={CHECKOUT_SESSION_ID}",
      "status" => "open",
      "currency" => "usd",
      "amount_total" => 1999
    }

    assert %Checkout{
             ui_mode: :embedded,
             client_secret: "cs_test_a1_secret_xyz",
             return_url: "https://shop.test/return?session_id={CHECKOUT_SESSION_ID}",
             url: nil
           } = Stripe.Mapper.checkout(session)

    assert %Checkout{ui_mode: :hosted, client_secret: nil} =
             Stripe.Mapper.checkout(%{
               session
               | "ui_mode" => "hosted_page",
                 "client_secret" => nil
             })
  end

  test "a held PaymentIntent is authorized, and one captured in part counts its refunds on the part" do
    held = %{
      "id" => "pi_1",
      "object" => "payment_intent",
      "amount" => 2000,
      "amount_capturable" => 2000,
      "amount_received" => 0,
      "capture_method" => "manual",
      "currency" => "usd",
      "status" => "requires_capture",
      "created" => 1_794_825_000,
      "latest_charge" => %{"id" => "ch_1", "amount_refunded" => 0, "captured" => false}
    }

    assert {:ok, %Payment{status: :authorized, amount_captured: nil}} =
             Stripe.Mapper.payment(held)

    captured = %{
      held
      | "status" => "succeeded",
        "amount_capturable" => 0,
        "amount_received" => 1200,
        "latest_charge" => %{"id" => "ch_1", "amount_refunded" => 1200, "captured" => true}
    }

    assert {:ok, %Payment{status: :refunded, amount: amount, amount_captured: part}} =
             Stripe.Mapper.payment(captured)

    assert {Money.to_string!(amount), Money.to_string!(part)} == {"$20.00", "$12.00"}

    assert {:ok, %Payment{status: :partially_refunded}} =
             Stripe.Mapper.payment(put_in(captured, ["latest_charge", "amount_refunded"], 200))

    assert Stripe.Mapper.capture_params(nil) == %{}
    assert Stripe.Mapper.capture_params(Money.new(:USD, "12")) == %{"amount_to_capture" => 1200}
    assert Stripe.Mapper.capture_params(Money.new(:ISK, "5")) == %{"amount_to_capture" => 500}
  end

  test "a dispute maps with its status, due date and evidence count" do
    assert {:ok,
            %MishkaPay.Dispute{
              id: "dp_1",
              payment_id: "pi_1",
              status: :needs_response,
              reason: "fraudulent",
              has_evidence: false,
              submission_count: 0,
              refundable: false,
              amount: amount
            }} =
             Stripe.Mapper.dispute(%{
               "id" => "dp_1",
               "object" => "dispute",
               "amount" => 1999,
               "currency" => "usd",
               "payment_intent" => "pi_1",
               "charge" => "ch_1",
               "status" => "needs_response",
               "reason" => "fraudulent",
               "is_charge_refundable" => false,
               "evidence_details" => %{
                 "due_by" => 1_795_000_000,
                 "has_evidence" => false,
                 "submission_count" => 0
               },
               "created" => 1_794_825_000
             })

    assert Money.equal?(amount, Money.new(:USD, "19.99"))
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

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.StripeTest do
  # Starts the Stripe plugin, which changes the providers event every test sees.
  use ExUnit.Case, async: false

  alias MishkaPay.{Checkout, Errors, Payment, Refund}
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

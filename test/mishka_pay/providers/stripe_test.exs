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
end

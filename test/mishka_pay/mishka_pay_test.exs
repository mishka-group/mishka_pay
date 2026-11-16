# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPayTest do
  # Starts provider and gate plugins, which change events every test sees.
  use ExUnit.Case, async: false

  alias MishkaPay.{Checkout, Errors, Payment, Refund}
  alias MishkaPay.Support.{Acme, CheckoutOnly, StockGate}

  @checkout %{
    provider: "acme",
    tenant: "site-a",
    items: [%{name: "Ebook", amount: %{amount: "19.99", currency: "USD"}}],
    success_url: "https://shop.test/thanks",
    cancel_url: "https://shop.test/cart",
    reference: "order-1"
  }

  setup do
    MishkaPay.Test.start_plugin!(Acme)
    MishkaPay.Test.put_keys("acme", %{secret_key: "sk_acme"})
    ref = :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :checkout, :stop]])
    %{ref: ref}
  end

  test "a checkout reaches the provider with the tenant's keys and comes back with its page", %{
    ref: ref
  } do
    assert {:ok,
            %Checkout{id: "acme_cs_order-1", url: "https://pay.acme.test/order-1", status: :open}} =
             MishkaPay.checkout(@checkout)

    assert_received {[:mishka_pay, :checkout, :stop], ^ref, _,
                     %{provider: "acme", tenant: "site-a", outcome: :ok}}
  end

  test "a declined checkout is a provider error, and telemetry says so", %{ref: ref} do
    assert {:error, %Errors.Declined{reason: "card_declined"}} =
             MishkaPay.checkout(%{@checkout | reference: "decline"})

    assert_received {[:mishka_pay, :checkout, :stop], ^ref, _, %{outcome: :provider}}
  end

  test "a checkout that is not valid never reaches the provider" do
    assert {:error, %Errors.Invalid{}} = MishkaPay.checkout(%{@checkout | items: []})
  end

  test "an unknown provider, a missing capability or missing keys stop before the provider" do
    assert {:error, %Errors.UnknownProvider{provider: "nope"}} =
             MishkaPay.checkout(%{@checkout | provider: "nope"})

    MishkaPay.Test.start_plugin!(CheckoutOnly)

    assert {:error, %Errors.Unsupported{provider: "checkout_only", operation: :refund}} =
             MishkaPay.refund(%{provider: "checkout_only", payment_id: "co_pi"})

    assert {:error, %Errors.MissingCredentials{provider: "checkout_only"}} =
             MishkaPay.checkout(%{@checkout | provider: "checkout_only"})
  end

  test "the host's gate can change a checkout or refuse it before the provider sees it" do
    MishkaPay.Test.start_plugin!(StockGate)

    assert {:ok, %Checkout{metadata: %{"channel" => "web"}}} = MishkaPay.checkout(@checkout)

    assert {:error, %Errors.Refused{operation: :checkout, reason: "the ebook is out of stock"}} =
             MishkaPay.checkout(%{@checkout | reference: "out-of-stock"})
  end

  @tag :capture_log
  test "a gate that answers junk, drops the checkout or exits refuses the sale" do
    MishkaPay.Test.start_plugin!(StockGate)

    for {reference, reason} <- [
          {"gate-junk", :invalid_answer},
          {"gate-no-checkout", :invalid_answer},
          {"gate-exit", :exited}
        ] do
      assert {:error, %Errors.Refused{reason: ^reason}} =
               MishkaPay.checkout(%{@checkout | reference: reference})
    end
  end

  # No time passes: a limit of 0 gives the hanging gate no time, and the refusal says why.
  test "a gate that never answers refuses at its time limit" do
    MishkaPay.Test.start_plugin!(StockGate)
    Application.put_env(:mishka_pay, :checkout_gate_timeout, 0)
    on_exit(fn -> Application.delete_env(:mishka_pay, :checkout_gate_timeout) end)

    assert {:error, %Errors.Refused{reason: :timeout}} =
             MishkaPay.checkout(%{@checkout | reference: "gate-hang"})
  end

  describe "subscriptions" do
    test "are read, cancelled at the period's end or now, taken back, and their invoices listed" do
      assert {:ok, %MishkaPay.Subscription{id: "acme_sub_active", status: :active, items: [plan]}} =
               MishkaPay.fetch_subscription("acme", "acme_sub_active", "site-a")

      assert {plan.interval, plan.amount} == {:month, Money.new(:USD, "9.00")}

      assert {:ok, %{status: :active, cancel_at_period_end: true}} =
               MishkaPay.cancel_subscription("acme", "acme_sub_active", "site-a")

      assert {:ok, %{status: :canceled}} =
               MishkaPay.cancel_subscription("acme", "acme_sub_active", "site-a", at: :now)

      assert {:ok, %{cancel_at_period_end: false}} =
               MishkaPay.resume_subscription("acme", "acme_sub_active", "site-a")

      assert {:ok, [%MishkaPay.Invoice{status: :paid, subscription_id: "acme_sub_active"}]} =
               MishkaPay.invoices("acme", "acme_sub_active", "site-a")

      assert_raise ArgumentError, ~r/must be :now or :period_end/, fn ->
        MishkaPay.cancel_subscription("acme", "acme_sub_active", "site-a", at: :tomorrow)
      end
    end

    test "a provider without subscriptions refuses a subscription checkout and every call" do
      MishkaPay.Test.start_plugin!(CheckoutOnly)

      monthly = %{name: "Pro", amount: %{amount: "9", currency: "USD"}, interval: :month}

      assert {:error, %Errors.Unsupported{operation: :subscription}} =
               MishkaPay.checkout(
                 %{
                   @checkout
                   | provider: "checkout_only",
                     items: [monthly]
                 }
                 |> Map.put(:mode, :subscription)
               )

      assert {:error, %Errors.Unsupported{operation: :subscription}} =
               MishkaPay.fetch_subscription("checkout_only", "sub_1")
    end
  end

  test "a checkout is read again by its id, with the payment it made" do
    assert {:ok, %Checkout{id: "acme_cs_o-9", status: :complete, payment_id: "acme_paid"}} =
             MishkaPay.fetch_checkout("acme", "acme_cs_o-9", "site-a")
  end

  test "a payment is read again from the provider, and a refund is made there" do
    assert {:ok, %Payment{id: "acme_paid", status: :paid}} =
             MishkaPay.fetch_payment("acme", "acme_paid", "site-a")

    assert {:ok, %Refund{id: "acme_re_1", status: :succeeded, payment_id: "acme_paid"}} =
             MishkaPay.refund(%{provider: "acme", tenant: "site-a", payment_id: "acme_paid"})
  end
end

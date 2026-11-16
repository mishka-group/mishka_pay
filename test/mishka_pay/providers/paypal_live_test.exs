# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.PayPalLiveTest do
  @moduledoc """
  Against PayPal's sandbox, the truth the stand-in (`MishkaPay.Support.PayPalStub`) copies. It
  runs only with a sandbox app's keys:

      PAYPAL_CLIENT_ID=... PAYPAL_CLIENT_SECRET=... mix test --only paypal_live

  A sandbox Order cannot be approved without a buyer in a browser, so these check what a server
  does alone: the token, creating an Order or a subscription with its plan, reading them back, and
  PayPal's own refusals.
  """

  use ExUnit.Case, async: false

  alias MishkaPay.{Checkout, Errors, Page, Payment, Price, Subscription}
  alias MishkaPay.Providers.PayPal

  @moduletag :paypal_live

  setup do
    MishkaPay.Test.start_plugin!(PayPal)

    MishkaPay.Test.put_keys("paypal", %{
      publishable_key: System.fetch_env!("PAYPAL_CLIENT_ID"),
      secret_key: System.fetch_env!("PAYPAL_CLIENT_SECRET"),
      mode: :test
    })

    MishkaPay.Test.stub_http(
      &MishkaPay.Support.StripeMock.forward(&1, "https://api-m.sandbox.paypal.com")
    )

    :ok
  end

  test "an Order opens on PayPal's sandbox and reads back as an open checkout and a waiting payment" do
    reference = "live-#{run_id()}"

    assert {:ok, %Checkout{id: id, status: :open, url: "https://www.sandbox.paypal.com/" <> _}} =
             MishkaPay.checkout(%{
               provider: "paypal",
               items: [%{name: "Ebook", amount: %{amount: "19.99", currency: "USD"}, quantity: 2}],
               success_url: "https://shop.test/thanks",
               cancel_url: "https://shop.test/cart",
               reference: reference
             })

    assert {:ok, %Checkout{id: ^id, status: :open, reference: ^reference, payment_id: nil}} =
             MishkaPay.fetch_checkout("paypal", id)

    assert {:ok, %Payment{id: ^id, status: :pending, amount: amount}} =
             MishkaPay.fetch_payment("paypal", id)

    assert amount == Money.new(:USD, "39.98")
  end

  test "a subscription with a trial opens on PayPal's sandbox, waiting for the buyer to approve it" do
    reference = "live-sub-#{run_id()}"

    assert {:ok, %Checkout{id: "I-" <> _ = id, status: :open, url: url}} =
             MishkaPay.checkout(%{
               provider: "paypal",
               mode: :subscription,
               trial_days: 7,
               items: [
                 %{
                   name: "Mishka Pro",
                   amount: %{amount: "9", currency: "USD"},
                   interval: :month,
                   quantity: 2
                 }
               ],
               success_url: "https://shop.test/thanks",
               cancel_url: "https://shop.test/cart",
               reference: reference
             })

    assert url =~ "https://www.sandbox.paypal.com/webapps/billing/subscriptions?ba_token="

    assert {:ok, %Checkout{status: :open, reference: ^reference, subscription_id: nil}} =
             MishkaPay.fetch_checkout("paypal", id)

    assert {:ok,
            %Subscription{
              status: :incomplete,
              reference: ^reference,
              items: [%Price{amount: amount, quantity: 2, interval: :month, interval_count: 1}]
            }} = MishkaPay.fetch_subscription("paypal", id)

    assert amount == Money.new(:USD, "9.00")
    assert {:ok, %Page{items: []}} = MishkaPay.list_invoices("paypal", nil, subscription_id: id)
    assert {:error, %Errors.Invalid{}} = MishkaPay.upcoming_invoice("paypal", id)
  end

  test "an Order that does not exist is PayPal's own rejection" do
    assert {:error, %Errors.Rejected{provider: "paypal", status: 404}} =
             MishkaPay.fetch_payment("paypal", "0000000000000000X")
  end

  # Stripe and PayPal keep codes, lookup keys and idempotency keys between runs; a counter alone
  # starts again each run, so the run's time makes every name new.
  defp run_id, do: "#{System.os_time(:millisecond)}#{System.unique_integer([:positive])}"
end

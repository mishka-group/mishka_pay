# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.PayPalLiveTest do
  @moduledoc """
  Against PayPal's sandbox, the truth the stand-in (`MishkaPay.Support.PayPalStub`) copies. It
  runs only with a sandbox app's keys:

      PAYPAL_CLIENT_ID=... PAYPAL_CLIENT_SECRET=... mix test --only paypal_live

  A sandbox Order cannot be approved without a buyer in a browser, so these check what a server
  does alone: the token, creating an Order, reading it back, and PayPal's own refusals.
  """

  use ExUnit.Case, async: false

  alias MishkaPay.{Checkout, Errors, Payment}
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
    reference = "live-#{System.unique_integer([:positive])}"

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

  test "an Order that does not exist is PayPal's own rejection" do
    assert {:error, %Errors.Rejected{provider: "paypal", status: 404}} =
             MishkaPay.fetch_payment("paypal", "0000000000000000X")
  end
end

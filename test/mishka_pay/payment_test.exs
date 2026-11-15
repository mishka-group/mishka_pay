# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.PaymentTest do
  use ExUnit.Case, async: true

  alias MishkaPay.{Errors, Payment, Refund}

  test "a payment keeps its money and one of the known statuses" do
    assert {:ok, %Payment{amount: amount, status: :paid}} =
             Payment.builder(%{
               provider: "stripe",
               id: "pi_1",
               amount: Money.new(:USD, "5"),
               status: :paid
             })

    assert amount == Money.new(:USD, "5.00")

    assert {:error, %Errors.Invalid{errors: [%{field: :status}]}} =
             Errors.from_builder(
               Payment.builder(%{
                 provider: "stripe",
                 id: "pi_1",
                 amount: Money.new(:USD, "5"),
                 status: :lost
               })
             )
  end

  test "a refund needs the payment; the amount may be left out for a full refund" do
    assert {:ok, %Refund{amount: nil, payment_id: "pi_1"}} =
             Refund.builder(%{provider: "stripe", payment_id: "pi_1"})

    assert {:ok, %Refund{amount: amount}} =
             Refund.builder(%{
               "provider" => "stripe",
               "payment_id" => "pi_1",
               "amount" => %{"amount" => "2.50", "currency" => "eur"}
             })

    assert amount == Money.new(:EUR, "2.50")

    assert {:error, %Errors.Invalid{errors: [%{field: :payment_id}]}} =
             Errors.from_builder(Refund.builder(%{provider: "stripe", payment_id: nil}))

    assert {:error, %Errors.Invalid{errors: [%{field: :reason}]}} =
             Errors.from_builder(
               Refund.builder(%{provider: "stripe", payment_id: "pi_1", reason: :bored})
             )
  end
end

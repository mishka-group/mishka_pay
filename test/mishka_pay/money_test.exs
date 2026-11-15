# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.MoneyTest do
  use ExUnit.Case, async: true

  alias GuardedStruct.Errors.Validation
  alias MishkaPay.{Errors, Money}

  test "money keeps an exact amount and an upper case currency" do
    assert {:ok, %Money{amount: amount, currency: "USD"}} = Money.new("19.99", " usd ")
    assert Decimal.equal?(amount, "19.99")

    assert {:ok, %Money{amount: amount}} = Money.new(5, "EUR")
    assert Decimal.equal?(amount, 5)

    assert {:ok, %Money{}} = Money.new(Decimal.new("0"), "JPY")
  end

  test "a float, a negative, a word or a missing amount is refused on the amount field" do
    for amount <- [19.99, -1, "-0.5", "ten", nil, "Infinity"] do
      assert {:error, %Errors.Invalid{errors: [%Validation{field: :amount}]}} =
               Money.new(amount, "USD")
    end
  end

  test "an amount with more decimal places than its currency has is refused" do
    assert {:error, %Errors.Invalid{errors: [%Validation{field: :amount}]}} =
             Money.new("19.999", "USD")

    assert {:error, %Errors.Invalid{}} = Money.new("100.5", "JPY")
    assert {:ok, %Money{}} = Money.new("1.234", "KWD")
    assert {:ok, %Money{}} = Money.new("19.90", "USD")
  end

  test "a currency that is not three letters is refused on the currency field" do
    for currency <- ["US", "USDT", "US1", "", nil] do
      assert {:error, %Errors.Invalid{errors: errors}} = Money.new(100, currency)
      assert Enum.all?(errors, &match?(%Validation{field: :currency}, &1))
    end
  end

  test "the smallest unit follows each currency's decimal places, both ways" do
    for {minor, currency} <- [{1999, "USD"}, {500, "JPY"}, {1234, "KWD"}, {0, "EUR"}] do
      assert {:ok, money} = Money.from_minor(minor, currency)
      assert Money.to_minor(money) == minor
    end

    assert {:ok, %Money{amount: amount}} = Money.from_minor(1999, "usd")
    assert Decimal.equal?(amount, "19.99")
    assert {:ok, money} = Money.new("500", "JPY")
    assert Money.to_minor(money) == 500
  end

  test "builder takes string keys, as a decoded answer has them, and refuses unknown keys" do
    assert {:ok, %Money{currency: "JPY"}} =
             Money.builder(%{"amount" => "500", "currency" => "jpy"})

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :rate}]}} =
             Errors.from_builder(Money.builder(%{amount: 1, currency: "USD", rate: 2}))
  end
end

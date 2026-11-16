# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.MoneyTest do
  use ExUnit.Case, async: true

  alias GuardedStruct.Errors.Validation
  alias MishkaPay.{Errors, Money}

  test "money is ex_money's, with an exact amount and the currency's places" do
    assert {:ok, %Elixir.Money{currency: :USD} = money} = Money.new("19.99", " usd ")
    assert Decimal.equal?(money.amount, "19.99")

    assert Money.new(5, "USD") == Money.new(" 5.00 ", :usd)
    assert {:ok, %Elixir.Money{amount: zero}} = Money.new("-0", "USD")
    assert Decimal.to_string(zero) == "0.00"
  end

  test "a float, a negative, a word, an infinity or a missing amount is refused on the amount field" do
    for amount <- [19.99, -1, "-0.5", "ten", nil, "Infinity", "NaN"] do
      assert {:error, %Errors.Invalid{errors: [%Validation{field: :amount}]}} =
               Money.new(amount, "USD")
    end
  end

  test "an amount too large to be a price is refused, never a crash" do
    for amount <- ["1e100", "1e400", Decimal.new("1E+400"), String.duplicate("9", 21)] do
      assert {:error, %Errors.Invalid{errors: [%Validation{field: :amount} = error]}} =
               Money.new(amount, "USD")

      assert error.message =~ "too large"
    end

    assert {:ok, _money} = Money.new(String.duplicate("9", 20) <> ".99", "USD")

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :amount}]}} =
             Money.from_minor(Integer.pow(10, 40), "USD")
  end

  test "an amount with more decimal places than its currency has is refused" do
    assert {:error, %Errors.Invalid{errors: [%Validation{field: :amount}]}} =
             Money.new("19.999", "USD")

    assert {:error, %Errors.Invalid{}} = Money.new("100.5", "JPY")
    assert {:ok, _money} = Money.new("1.234", "KWD")
  end

  test "a currency that is not a known ISO 4217 code is refused on the currency field" do
    for currency <- ["US", "ZZZ", "US1", "", nil, 42] do
      assert {:error, %Errors.Invalid{errors: [%Validation{field: :currency}]}} =
               Money.new(100, currency)
    end
  end

  test "the smallest unit follows each currency's places, both ways" do
    for {minor, currency} <- [{1999, "USD"}, {500, "JPY"}, {1234, "KWD"}, {0, "EUR"}] do
      assert {:ok, money} = Money.from_minor(minor, currency)
      assert Money.to_minor(money) == minor
    end

    assert {:ok, money} = Money.from_minor(1999, "usd")
    assert Decimal.equal?(money.amount, "19.99")
  end

  test "a negative smallest unit from a provider is an error, never a crash" do
    assert {:error, %Errors.Invalid{errors: [%Validation{field: :amount}]}} =
             Money.from_minor(-5, "USD")

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :currency}]}} =
             Money.from_minor(5, "ZZZ")
  end

  test "as a field validator, money comes from a Money or a map with string or atom keys" do
    assert {:ok, :price, %Elixir.Money{currency: :USD}} =
             Money.field(:price, Elixir.Money.new(:USD, "5"))

    assert {:ok, :price, %Elixir.Money{currency: :EUR}} =
             Money.field(:price, %{"amount" => "5", "currency" => "eur"})

    assert {:ok, :price, nil} = Money.field(:price, nil)
    assert {:error, :price, message} = Money.field(:price, %{amount: 5.5, currency: "USD"})
    assert message =~ "exact"
    assert {:error, :price, _message} = Money.field(:price, "5 USD")
  end

  test "a provider that counts a currency in other places than ISO 4217 converts both ways" do
    {:ok, isk} = Money.new("5", "ISK")
    assert Money.to_minor(isk, 2) == 500
    assert {:ok, ^isk} = Money.from_minor(500, "ISK", 2)

    {:ok, mga} = Money.new("1000", "MGA")
    assert Money.to_minor(mga) == 100_000
    assert Money.to_minor(mga, 0) == 1000
    assert {:ok, ^mga} = Money.from_minor(1000, "MGA", 0)

    assert Money.fits?(mga, 0)
    {:ok, part} = Money.new("10.50", "MGA")
    refute Money.fits?(part, 0)

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :amount}]}} =
             Money.from_minor(550, "ISK", 2)
  end
end

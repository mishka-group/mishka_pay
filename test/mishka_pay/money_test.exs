# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.MoneyTest do
  use ExUnit.Case, async: true

  alias GuardedStruct.Errors.Validation
  alias MishkaPay.{Errors, Money}

  test "money keeps a whole amount and an upper case currency" do
    assert {:ok, %Money{amount: 1999, currency: "USD"}} = Money.new(1999, " usd ")
    assert {:ok, %Money{amount: 0}} = Money.new(0, "EUR")
  end

  test "a negative or a float amount is refused on the amount field" do
    for amount <- [-1, 19.99, "1999", nil] do
      assert {:error, %Errors.Invalid{errors: [%Validation{field: :amount}]}} =
               Money.new(amount, "USD")
    end
  end

  test "a currency that is not three letters is refused on the currency field" do
    for currency <- ["US", "USDT", "US1", "", nil] do
      assert {:error, %Errors.Invalid{errors: errors}} = Money.new(100, currency)
      assert Enum.all?(errors, &match?(%Validation{field: :currency}, &1))
    end
  end

  test "builder takes string keys, as a decoded provider answer has them, and refuses unknown keys" do
    assert {:ok, %Money{amount: 500, currency: "JPY"}} =
             Money.builder(%{"amount" => 500, "currency" => "jpy"})

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :rate}]}} =
             Errors.from_builder(Money.builder(%{amount: 1, currency: "USD", rate: 2}))
  end
end

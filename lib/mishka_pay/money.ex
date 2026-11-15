# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Money do
  @moduledoc """
  Money in Mishka Pay is [ex_money](https://hex.pm/packages/ex_money)'s `Money`: a `Decimal`
  amount and an ISO 4217 currency, with every currency's decimal places, cash rounding and
  formatting in any language from CLDR (`Money.to_string(money, locale: :de)`).

  This module is the check Mishka Pay puts around it before money reaches a provider:

    * the amount is a `Decimal`, an integer or a string; a float is refused, since `0.1 + 0.2` is
      not `0.3`;
    * the amount is zero or more: a refund is its own record with a positive amount;
    * the amount has no more decimal places than its currency (two for USD, none for JPY, three
      for KWD), and is kept with exactly those places, so `5` and `"5.00"` dollars are equal;
    * the currency is a known ISO 4217 code, in any case and with spaces trimmed.

      MishkaPay.Money.new("19.99", "usd")
      #=> {:ok, Money.new(:USD, "19.99")}

  Providers count in the smallest unit (cents): `from_minor/2` and `to_minor/1` convert. Every
  error is an `:invalid` class `MishkaPay.Errors` error naming `:amount` or `:currency`.
  """

  alias MishkaPay.Errors

  @doc "Checked money of `amount` in `currency`."
  @spec new(Decimal.t() | integer() | String.t(), String.t() | atom()) ::
          {:ok, Money.t()} | {:error, Splode.Error.t()}
  def new(amount, currency) do
    with {:ok, code} <- currency(currency),
         {:ok, amount} <- amount(amount),
         {:ok, money} <- money(code, amount) do
      in_places(money)
    end
  end

  @doc """
  Money from an amount in the currency's smallest unit, as a provider gives it:
  `from_minor(1999, "USD")` is 19.99 dollars.
  """
  @spec from_minor(integer(), String.t() | atom()) ::
          {:ok, Money.t()} | {:error, Splode.Error.t()}
  def from_minor(minor, currency) when is_integer(minor) do
    with {:ok, code} <- currency(currency),
         %Money{} = money <- Money.from_integer(minor, code) do
      new(money.amount, code)
    else
      {:error, _reason} = error -> error
    end
  end

  @doc "The amount in the currency's smallest unit, as a provider takes it: 19.99 dollars is 1999."
  @spec to_minor(Money.t()) :: integer()
  def to_minor(%Money{} = money) do
    {_currency, minor, _exponent, _remainder} = Money.to_integer_exp(money)
    minor
  end

  defp currency(code) when is_binary(code) or is_atom(code) do
    case code |> to_string() |> String.trim() |> String.upcase() |> Money.validate_currency() do
      {:ok, code} -> {:ok, code}
      {:error, _unknown} -> invalid(:currency, "The currency field must be a known ISO 4217 code")
    end
  end

  defp currency(_code), do: invalid(:currency, "The currency field must be a known ISO 4217 code")

  defp amount(amount) when is_float(amount),
    do: invalid(:amount, "The amount field must be exact: a Decimal, an integer or a string")

  defp amount(amount) when is_binary(amount), do: amount |> String.trim() |> decimal()
  defp amount(amount), do: decimal(amount)

  defp decimal(value) do
    with {:ok, decimal} <- Decimal.cast(value),
         false <- Decimal.inf?(decimal) or Decimal.nan?(decimal) do
      non_negative(decimal)
    else
      _not_a_number -> invalid(:amount, "The amount field must be a number")
    end
  end

  # `Decimal.add/2` turns a negative zero into zero.
  defp non_negative(decimal) do
    case Decimal.negative?(decimal) do
      true -> invalid(:amount, "The amount field must be zero or more")
      false -> {:ok, Decimal.add(decimal, 0)}
    end
  end

  defp money(code, amount) do
    case Money.new(code, amount) do
      %Money{} = money -> {:ok, money}
      {:error, _reason} -> invalid(:amount, "The amount field must be a number")
    end
  end

  # Rounding to the currency's ISO places changes nothing when the amount already fits them.
  defp in_places(money) do
    rounded = Money.round(money, currency_digits: :iso)

    case Decimal.equal?(rounded.amount, money.amount) do
      true ->
        {:ok, rounded}

      false ->
        invalid(:amount, "The amount field has more decimal places than #{money.currency} has")
    end
  end

  defp invalid(field, message),
    do: Errors.from_builder({:error, [%{field: field, action: :money, message: message}]})
end

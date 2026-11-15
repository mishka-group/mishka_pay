# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Money do
  @moduledoc """
  Money in Mishka Pay is [ex_money](https://hex.pm/packages/ex_money)'s `Money`: a `Decimal`
  amount and an ISO 4217 currency, with every currency's decimal places, cash rounding and
  formatting in any language from CLDR (`Money.to_string(money, locale: :de)`).

  Only English locale data ships with `localize`. A project that formats money in other languages
  downloads their data once at build time, for example `mix localize.download_locales de fr`, and
  names them in `config :localize, supported_locales: [:en, :de, :fr]`. Without that,
  `Money.to_string/2` answers in English, with no error.

  This module is the check Mishka Pay puts around it before money reaches a provider:

    * the amount is a `Decimal`, an integer or a string; a float is refused, since `0.1 + 0.2` is
      not `0.3`;
    * the amount is zero or more: a refund is its own record with a positive amount;
    * the amount has at most twenty digits before the decimal point;
    * the amount has no more decimal places than its currency (two for USD, none for JPY, three
      for KWD), and is kept with exactly those places, so `5` and `"5.00"` dollars are equal;
    * the currency is a known ISO 4217 code, in any case and with spaces trimmed.

      MishkaPay.Money.new("19.99", "usd")
      #=> {:ok, Money.new(:USD, "19.99")}

  Providers count in the smallest unit (cents): `from_minor/2` and `to_minor/1` convert. Every
  error is an `:invalid` class `MishkaPay.Errors` error naming `:amount` or `:currency`.
  """

  alias MishkaPay.Errors

  # More than any price, and well inside Decimal's default precision of 28 digits, which every
  # sum and rounding of the amount runs in.
  @max_digits 20

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
  A guarded_struct field validator for money: `validator: {MishkaPay.Money, :field}`. It takes a
  `Money` struct or a map with `amount` and `currency` (atom or string keys, as JSON gives them),
  checks it with `new/2` and keeps the checked `Money`.
  """
  @spec field(atom(), term()) :: {:ok, atom(), Money.t()} | {:error, atom(), String.t()}
  def field(name, %Money{amount: amount, currency: currency}), do: checked(name, amount, currency)

  def field(name, %{} = map) do
    keys = Map.new(map, fn {key, value} -> {to_string(key), value} end)
    checked(name, keys["amount"], keys["currency"])
  end

  def field(name, nil), do: {:ok, name, nil}

  def field(name, _other),
    do: {:error, name, "The #{name} field must be money: an amount and a currency"}

  defp checked(name, amount, currency) do
    case new(amount, currency) do
      {:ok, money} -> {:ok, name, money}
      {:error, %{errors: [%{message: message} | _]}} -> {:error, name, message}
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

  defp non_negative(decimal) do
    cond do
      Decimal.negative?(decimal) -> invalid(:amount, "The amount field must be zero or more")
      whole_digits(decimal) > @max_digits -> invalid(:amount, "The amount field is too large")
      true -> {:ok, positive_zero(decimal)}
    end
  end

  # Digits before the decimal point, counted on the coefficient and exponent: no arithmetic, so a
  # huge exponent such as "1e400" is measured without raising.
  defp whole_digits(%Decimal{coef: 0}), do: 0

  defp whole_digits(%Decimal{coef: coef, exp: exp}),
    do: max(length(Integer.digits(coef)) + exp, 0)

  defp positive_zero(%Decimal{coef: 0} = zero), do: %{zero | sign: 1}
  defp positive_zero(decimal), do: decimal

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

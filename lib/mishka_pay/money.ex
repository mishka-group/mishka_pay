# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Money do
  @moduledoc """
  An amount and its currency. The amount is a `Decimal` in the currency's main unit (`19.99` US
  dollars), so no float ever carries money; the currency is an ISO 4217 code, kept upper case.

      MishkaPay.Money.new("19.99", "usd")
      #=> {:ok, %MishkaPay.Money{amount: Decimal.new("19.99"), currency: "USD"}}

  The amount takes a `Decimal`, an integer or a string. A float is refused: `0.1 + 0.2` is not
  `0.3`, and money must be exact. An amount is never below zero (a refund is its own record with a
  positive amount) and has no more decimal places than its currency: two for USD, none for JPY,
  three for KWD.

  Providers count in the smallest unit (cents). `to_minor/1` and `from_minor/2` convert, with the
  ISO 4217 number of decimal places of each currency; a provider whose own count differs for a
  currency adjusts in its adapter.

  A guarded_struct, so `builder/1` takes a map with atom or string keys and refuses keys it does
  not know. `new/2` returns its errors as `MishkaPay.Errors`.
  """

  use GuardedStruct

  alias MishkaPay.Errors
  alias MishkaPay.Helpers.Required

  # ISO 4217 currencies whose minor unit is not two decimal places. Every other code has two.
  @digits %{
    "BIF" => 0,
    "CLP" => 0,
    "DJF" => 0,
    "GNF" => 0,
    "ISK" => 0,
    "JPY" => 0,
    "KMF" => 0,
    "KRW" => 0,
    "PYG" => 0,
    "RWF" => 0,
    "UGX" => 0,
    "UYI" => 0,
    "VND" => 0,
    "VUV" => 0,
    "XAF" => 0,
    "XOF" => 0,
    "XPF" => 0,
    "BHD" => 3,
    "IQD" => 3,
    "JOD" => 3,
    "KWD" => 3,
    "LYD" => 3,
    "OMR" => 3,
    "TND" => 3,
    "CLF" => 4,
    "UYW" => 4
  }

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :fits_currency} do
    field :amount, Decimal.t(), enforce: true, validator: {__MODULE__, :amount}

    field :currency, String.t(),
      enforce: true,
      derives: "sanitize(trim, upcase) validate(string)",
      validator: {__MODULE__, :currency}
  end

  @doc "Money of `amount` in `currency`, or an `:invalid` class error naming the field."
  @spec new(Decimal.t() | integer() | String.t(), String.t()) ::
          {:ok, t()} | {:error, Splode.Error.t()}
  def new(amount, currency),
    do: Errors.from_builder(builder(%{amount: amount, currency: currency}))

  @doc """
  Money from an amount in the currency's smallest unit, as a provider gives it:
  `from_minor(1999, "USD")` is 19.99 dollars.
  """
  @spec from_minor(integer(), String.t()) :: {:ok, t()} | {:error, Splode.Error.t()}
  def from_minor(minor, currency) when is_integer(minor) and is_binary(currency) do
    code = currency |> String.trim() |> String.upcase()
    new(Decimal.new(1, minor, -digits(code)), code)
  end

  @doc "The amount in the currency's smallest unit, as a provider takes it: 19.99 dollars is 1999."
  @spec to_minor(t()) :: integer()
  def to_minor(%__MODULE__{amount: amount, currency: currency}),
    do: amount |> Decimal.mult(Decimal.new(1, 1, digits(currency))) |> Decimal.to_integer()

  @doc "How many decimal places `currency` has, by ISO 4217: 2 for USD, 0 for JPY, 3 for KWD."
  @spec digits(String.t()) :: non_neg_integer()
  def digits(currency), do: Map.get(@digits, currency, 2)

  @doc false
  def amount(:amount, nil), do: Required.call(:amount, nil)

  def amount(:amount, value) when is_float(value),
    do: {:error, :amount, "The amount field must be exact: a Decimal, an integer or a string"}

  def amount(:amount, value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> non_negative(decimal)
      :error -> {:error, :amount, "The amount field must be a number"}
    end
  end

  defp non_negative(decimal) do
    case Decimal.negative?(decimal) or Decimal.inf?(decimal) or Decimal.nan?(decimal) do
      true -> {:error, :amount, "The amount field must be zero or more"}
      false -> {:ok, :amount, decimal}
    end
  end

  # A validator runs before `derives`, so the code is not trimmed or upper case yet; anything else
  # not a string is left to `validate(string)`.
  @doc false
  def currency(:currency, nil), do: Required.call(:currency, nil)

  def currency(:currency, code) when is_binary(code) do
    case Regex.match?(~r/^\s*[A-Za-z]{3}\s*$/, code) do
      true -> {:ok, :currency, code}
      false -> {:error, :currency, "The currency field must be a three letter ISO 4217 code"}
    end
  end

  def currency(:currency, code), do: {:ok, :currency, code}

  # After every field passed: the amount has no more decimal places than its currency.
  @doc false
  def fits_currency(%{amount: %Decimal{} = amount, currency: currency} = attrs) do
    allowed = digits(currency)

    case places(amount) <= allowed do
      true ->
        {:ok, attrs}

      false ->
        {:error,
         %{
           field: :amount,
           action: :currency_places,
           message: "The amount field has more than #{allowed} decimal places for #{currency}"
         }}
    end
  end

  def fits_currency(attrs), do: {:ok, attrs}

  defp places(amount) do
    case Decimal.normalize(amount) do
      %Decimal{exp: exp} when exp < 0 -> -exp
      _whole -> 0
    end
  end
end

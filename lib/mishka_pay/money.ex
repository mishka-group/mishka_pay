# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Money do
  @moduledoc """
  An amount and its currency. The amount is a whole number in the currency's smallest unit (cents
  for USD, yen for JPY), so no float ever carries money; the currency is an ISO 4217 code, kept
  upper case.

      MishkaPay.Money.new(1999, "usd")
      #=> {:ok, %MishkaPay.Money{amount: 1999, currency: "USD"}}

  An amount is never below zero: a refund is its own record with a positive amount.

  A guarded_struct, so `builder/1` takes a map with atom or string keys and refuses keys it does
  not know. `new/2` returns its errors as `MishkaPay.Errors`.
  """

  use GuardedStruct

  alias MishkaPay.Errors

  guardedstruct authorized_fields: true do
    field(:amount, non_neg_integer(),
      enforce: true,
      derives: "validate(integer, min_len=0)",
      validator: {__MODULE__, :present}
    )

    field(:currency, String.t(),
      enforce: true,
      derives: "sanitize(trim, upcase) validate(string)",
      validator: {__MODULE__, :currency}
    )
  end

  @doc "Money of `amount` smallest units in `currency`, or an `:invalid` class error."
  @spec new(non_neg_integer(), String.t()) :: {:ok, t()} | {:error, Splode.Error.t()}
  def new(amount, currency),
    do: Errors.from_builder(builder(%{amount: amount, currency: currency}))

  # guarded_struct skips every `derives` op, `not_nil_value` included, on a field given as nil, and
  # `enforce` only asks for the key. A validator is called with nil, so it refuses it here.
  @doc false
  def present(field, nil), do: {:error, field, "The #{field} field is required"}
  def present(field, value), do: {:ok, field, value}

  # A validator runs before `derives`, so the code is not trimmed or upper case yet; anything else
  # not a string is left to `validate(string)`.
  @doc false
  def currency(:currency, nil), do: present(:currency, nil)

  def currency(:currency, code) when is_binary(code) do
    case Regex.match?(~r/^\s*[A-Za-z]{3}\s*$/, code) do
      true -> {:ok, :currency, code}
      false -> {:error, :currency, "The currency field must be a three letter ISO 4217 code"}
    end
  end

  def currency(:currency, code), do: {:ok, :currency, code}
end

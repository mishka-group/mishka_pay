# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Usage do
  @moduledoc """
  One report of what a customer used, sent with `MishkaPay.report_usage/1` to the
  `MishkaPay.Meter` that counts its `:event_name`. A price on that meter bills it at the end of
  the period. A guarded_struct.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:event_name`: the meter's event name.
    * `:customer_id`: the provider customer who used it (`MishkaPay.create_customer/1`).
    * `:value`: how much, 1 by default: an integer, a `Decimal` or a number in a string. A
      negative value takes back usage reported by mistake.
    * `:at`: when it was used, a `DateTime`; now when left out.
    * `:reference`: the caller's own id for this use, such as a request id. It makes the
      provider's id of the report and its idempotency key, so the same reference never counts
      twice.

  What the provider fills in: `:id`, its own id of the report.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :event_name, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty, max_len=100)"

    field :customer_id, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :value, integer() | Decimal.t(), default: 1, validator: {__MODULE__, :value}
    field :at, DateTime.t(), derives: "validate(struct)"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    field :id, String.t(), derives: "validate(string)"
  end

  # An exact number: a float is refused, as for money, since `0.1 + 0.2` is not `0.3`.
  @doc false
  def value(field, value) when is_integer(value), do: {:ok, field, value}
  # Infinity and NaN carry an atom as their coefficient.
  def value(field, %Decimal{coef: coef} = value) when is_integer(coef), do: {:ok, field, value}

  def value(field, value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {%Decimal{coef: coef} = decimal, ""} when is_integer(coef) -> {:ok, field, decimal}
      _not_a_number -> not_exact(field)
    end
  end

  def value(field, _other), do: not_exact(field)

  defp not_exact(field), do: {:error, field, MishkaPay.Messages.text(:usage_value)}
end

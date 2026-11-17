# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.CreditNoteLine do
  @moduledoc """
  One line of a `MishkaPay.CreditNote`: what it takes back of a bill. A guarded_struct.

  What the caller gives, one of two kinds:

    * a line of the bill: `:invoice_line_id` (`MishkaPay.InvoiceLine`'s id, `il_...` at Stripe),
      with a `:quantity` of it to credit, or an `:amount` (a part of the line's amount);
    * a line of its own: a `:name` and a `:unit_amount` (the credit for one), with a `:quantity`
      (1 unless given).

  What the provider fills in: `:id` (`cnli_...` at Stripe), `:type` (`:invoice_line` or
  `:custom`) and `:amount`, the line's whole credit.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :names_what} do
    field :id, String.t(), derives: "validate(string)"
    field :type, :invoice_line | :custom, derives: "validate(enum=Atom[invoice_line::custom])"

    field :invoice_line_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :name, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=500)"
    field :quantity, pos_integer(), derives: "validate(integer, min_len=1)"
    field :unit_amount, Money.t(), validator: {MishkaPay.Money, :field}
    field :amount, Money.t(), validator: {MishkaPay.Money, :field}
  end

  # A line to credit names a line of the bill with how much of it, or a line of its own with its
  # name and the credit for one. A line the provider answered (it has an id or a type) is taken
  # as it is.
  @doc false
  def names_what(attrs) do
    case {key(attrs, :id) || key(attrs, :type), key(attrs, :invoice_line_id), key(attrs, :name),
          key(attrs, :unit_amount)} do
      {nil, nil, name, unit} when is_nil(name) or is_nil(unit) -> needs()
      {nil, line, _name, _unit} when not is_nil(line) -> how_much(attrs)
      _named -> {:ok, attrs}
    end
  end

  defp how_much(attrs) do
    case is_nil(key(attrs, :quantity)) and is_nil(key(attrs, :amount)) do
      true -> needs()
      false -> {:ok, attrs}
    end
  end

  defp needs do
    {:error,
     %{
       field: :lines,
       action: :credit_note_line,
       message: MishkaPay.Messages.text(:credit_line_needs)
     }}
  end

  defp key(map, name), do: Map.get(map, name) || Map.get(map, Atom.to_string(name))
end

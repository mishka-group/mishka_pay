# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.CreditNote do
  @moduledoc """
  A credit note: the tax-correct way to take back part or all of a finalized bill, instead of
  changing it. Made with `MishkaPay.create_credit_note/1` (try it first with
  `MishkaPay.preview_credit_note/1`), read with `MishkaPay.fetch_credit_note/3`, listed with
  `MishkaPay.list_credit_notes/3` and `MishkaPay.list_credit_note_lines/4`, and ended with
  `MishkaPay.void_credit_note/3`. A guarded_struct.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:invoice_id`: the finalized bill it credits (`MishkaPay.Invoice`).
    * What it credits, one of them: an `:amount` of the whole bill, or `:lines`, each a
      `MishkaPay.CreditNote.Lines` (a line of the bill, or a line of its own).
    * `:reason`: `:duplicate`, `:fraudulent`, `:order_change` or `:product_unsatisfactory`.
    * Where the money goes, on a paid bill: `:refund_amount` back to the buyer's card,
      `:credit_amount` onto the customer's balance (taken off their next bills),
      `:out_of_band_amount` given back outside the provider. Together they make the note's
      amount. On an open bill the note lowers what is still due instead.
    * `:memo`: text on the note the buyer sees.
    * `:reference`: the caller's own id for it; it makes the idempotency key, so the same
      reference never credits twice, and it comes back on it.
    * `:metadata`: extra pairs, string keys to string values.

  Every amount is in the bill's currency.

  What the provider fills in: `:id` (`cn_...` at Stripe), `:number`, `:status` (`:issued` or
  `:void`), `:type` (`:pre_payment` when the bill was open, `:post_payment` when it was paid,
  `:mixed`), `:customer_id`, `:amount` (all of it, tax included), `:amount_tax`, the `:lines`,
  `:refund_ids` (the refunds it made), `:pdf_url`, `:voided_at` and `:created_at`. A preview
  answers the same, from a note not made.

  ## Lines

  Each of `:lines` is a `MishkaPay.CreditNote.Lines`, a sub_field of this struct: what the note
  takes back of the bill. `MishkaPay.list_credit_note_lines/4` answers them too. What the caller
  gives, one of two kinds:

    * a line of the bill: `:invoice_line_id` (a `MishkaPay.Invoice.Lines` id, `il_...` at
      Stripe), with a `:quantity` of it to credit, or an `:amount` (a part of the line's amount);
    * a line of its own: a `:name` and a `:unit_amount` (the credit for one), with a `:quantity`
      (1 unless given).

  What the provider fills in: `:id` (`cnli_...` at Stripe), `:type` (`:invoice_line` or
  `:custom`) and `:amount`, the line's whole credit.
  """

  use GuardedStruct

  @reasons ~w(duplicate fraudulent order_change product_unsatisfactory)a
  @money [:amount, :refund_amount, :credit_amount, :out_of_band_amount]

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :credits} do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()
    field :id, String.t(), derives: "validate(string)"
    field :invoice_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :customer_id, String.t(), derives: "validate(string)"
    field :amount, Money.t(), validator: {MishkaPay.Money, :field}

    sub_field :lines, [MishkaPay.CreditNote.Lines.t()],
      structs: true,
      authorized_fields: true,
      main_validator: {__MODULE__, :names_what},
      derives: "validate(list)" do
      field :id, String.t(), derives: "validate(string)"
      field :type, :invoice_line | :custom, derives: "validate(enum=Atom[invoice_line::custom])"
      field :invoice_line_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"

      field :name, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=500)"

      field :quantity, pos_integer(), derives: "validate(integer, min_len=1)"
      field :unit_amount, Money.t(), validator: {MishkaPay.Money, :field}
      field :amount, Money.t(), validator: {MishkaPay.Money, :field}
    end

    field :reason, :duplicate | :fraudulent | :order_change | :product_unsatisfactory,
      derives: "validate(enum=Atom[duplicate::fraudulent::order_change::product_unsatisfactory])",
      validator: {__MODULE__, :reason}

    field :refund_amount, Money.t(), validator: {MishkaPay.Money, :field}
    field :credit_amount, Money.t(), validator: {MishkaPay.Money, :field}
    field :out_of_band_amount, Money.t(), validator: {MishkaPay.Money, :field}
    field :memo, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=5000)"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}

    field :number, String.t(), derives: "validate(string)"
    field :status, :issued | :void, derives: "validate(enum=Atom[issued::void])"

    field :type, :pre_payment | :post_payment | :mixed,
      derives: "validate(enum=Atom[pre_payment::post_payment::mixed])"

    field :amount_tax, Money.t(), validator: {MishkaPay.Money, :field}
    field :refund_ids, list(), default: [], derives: "validate(list)"
    field :pdf_url, String.t(), derives: "validate(string)"
    field :voided_at, DateTime.t(), derives: "validate(struct)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  @doc false
  def reason(field, value), do: MishkaPay.Helpers.Choice.atom(field, value, @reasons)

  # A note to make names its bill and credits an amount or lines, one of them, with every amount
  # in one currency. A note the provider answered (it has an id or a status) is taken as it is.
  # It runs on the caller's map, before the fields are built.
  @doc false
  def credits(attrs) do
    case {key(attrs, :id) || key(attrs, :status), key(attrs, :amount), key(attrs, :lines)} do
      {nil, amount, lines} when is_nil(amount) == lines in [nil, []] ->
        invalid(:amount, :credit_note_one_of)

      {nil, _amount, _lines} ->
        one_currency(attrs)

      _answered ->
        {:ok, attrs}
    end
  end

  defp one_currency(attrs) do
    lines = List.wrap(key(attrs, :lines))

    attrs
    |> amounts(@money)
    |> Kernel.++(Enum.flat_map(lines, &amounts(&1, [:amount, :unit_amount])))
    |> Enum.uniq()
    |> case do
      [_first, _second | _more] -> invalid(:amount, :items_currency)
      _one_or_none -> {:ok, attrs}
    end
  end

  defp amounts(%{} = map, fields) do
    Enum.flat_map(fields, fn field ->
      case MishkaPay.Money.field(field, key(map, field)) do
        {:ok, ^field, %Money{currency: currency}} -> [currency]
        _none_or_wrong -> []
      end
    end)
  end

  defp amounts(_not_a_map, _fields), do: []

  # A line to credit names a line of the bill with how much of it, or a line of its own with its
  # name and the credit for one. A line the provider answered (it has an id or a type) is taken
  # as it is.
  @doc false
  def names_what(attrs) do
    case {key(attrs, :id) || key(attrs, :type), key(attrs, :invoice_line_id), key(attrs, :name),
          key(attrs, :unit_amount)} do
      {nil, nil, name, unit} when is_nil(name) or is_nil(unit) -> line_needs()
      {nil, line, _name, _unit} when not is_nil(line) -> how_much(attrs)
      _named -> {:ok, attrs}
    end
  end

  defp how_much(attrs) do
    case is_nil(key(attrs, :quantity)) and is_nil(key(attrs, :amount)) do
      true -> line_needs()
      false -> {:ok, attrs}
    end
  end

  defp line_needs do
    {:error,
     %{
       field: :lines,
       action: :credit_note_line,
       message: MishkaPay.Messages.text(:credit_line_needs)
     }}
  end

  defp invalid(field, message),
    do: {:error, %{field: field, action: :credit_note, message: MishkaPay.Messages.text(message)}}

  defp key(map, name), do: Map.get(map, name) || Map.get(map, Atom.to_string(name))
end

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
      `MishkaPay.CreditNoteLine` (a line of the bill, or a line of its own).
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
  """

  use GuardedStruct

  @reasons ~w(duplicate fraudulent order_change product_unsatisfactory)
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
    field :lines, list(), structs: MishkaPay.CreditNoteLine, derives: "validate(list)"

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

  defp invalid(field, message),
    do: {:error, %{field: field, action: :credit_note, message: MishkaPay.Messages.text(message)}}

  defp key(map, name), do: Map.get(map, name) || Map.get(map, Atom.to_string(name))
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.InvoiceItem do
  @moduledoc """
  One charge for a customer kept on its own, outside `MishkaPay.create_invoice/1`: a setup fee, an
  extra seat, a late fee. Left off any bill it waits (pending) and goes on the customer's next
  bill, a subscription's renewal or a one-off bill; given `:invoice_id` it goes on that draft
  bill. Made with `MishkaPay.create_invoice_item/1`, changed with
  `MishkaPay.update_invoice_item/1`, listed with `MishkaPay.list_invoice_items/3` and removed
  with `MishkaPay.delete_invoice_item/3`. A guarded_struct.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:customer_id`: whose bill it goes on.
    * `:invoice_id`: a draft bill to put it on; left out, it waits for the customer's next bill.
    * What it charges: a catalog price by `:price_id`, or a `:name` with an `:amount` (the price
      of one); `:quantity` (1 unless given), `:tax_code`, `:tax_behavior` and `:tax_rate_ids`
      (the seller's own `MishkaPay.TaxRate`s on it) as on a `MishkaPay.Price`.
    * `:reference`: the caller's own id for it; it makes the idempotency key, so the same reference
      never charges twice, and it comes back on it.
    * `:metadata`: extra pairs, string keys to string values.

  What the provider fills in: `:id` (`ii_...` at Stripe), `:total` (the amount times the quantity;
  below zero for a credit), `:period_start` and `:period_end`, `:created_at`.

  A change (`:id` given) names only what it changes: `:name`, `:amount` (in the item's own
  currency), `:quantity`, `:price_id`, the tax fields, `:metadata`. An item stays on its customer
  and bill; once its bill is finalized it cannot change or go.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :charges} do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :customer_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :invoice_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :price_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :name, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=500)"
    field :amount, Money.t(), validator: {MishkaPay.Money, :signed_field}
    field :quantity, pos_integer(), derives: "validate(integer, min_len=1)"

    field :tax_code, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=100)"

    field :tax_behavior, :inclusive | :exclusive,
      derives: "validate(enum=Atom[inclusive::exclusive])",
      validator: {MishkaPay.Price, :tax_behavior}

    field :tax_rate_ids, list(), validator: {MishkaPay.TaxRate, :ids}
    field :total, Money.t(), validator: {MishkaPay.Money, :signed_field}
    field :period_start, DateTime.t(), derives: "validate(struct)"
    field :period_end, DateTime.t(), derives: "validate(struct)"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  @doc """
  What a new item charges, as a `MishkaPay.Price` (its catalog price, or its name, amount and
  quantity): the line a provider's bill takes.
  """
  @spec price(t()) :: MishkaPay.Price.t()
  def price(%__MODULE__{} = item) do
    struct(MishkaPay.Price,
      id: item.price_id,
      name: item.name,
      amount: item.amount,
      quantity: item.quantity,
      tax_code: item.tax_code,
      tax_behavior: item.tax_behavior,
      tax_rate_ids: item.tax_rate_ids
    )
  end

  # A new item (no id yet) names what it charges: a catalog price, or a name with an amount. It
  # runs on the caller's map, before the fields are built.
  @doc false
  def charges(attrs) do
    case {key(attrs, :id), key(attrs, :price_id), key(attrs, :name), key(attrs, :amount)} do
      {nil, nil, name, amount} when is_nil(name) or is_nil(amount) ->
        {:error,
         %{field: :amount, action: :invoice_item, message: MishkaPay.Messages.text(:price_needs)}}

      _charges ->
        {:ok, attrs}
    end
  end

  defp key(map, name), do: Map.get(map, name) || Map.get(map, Atom.to_string(name))
end

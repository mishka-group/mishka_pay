# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Invoice do
  @moduledoc """
  One bill, as `MishkaPay.list_invoices/3` lists them and `MishkaPay.fetch_invoice/3` reads one; a
  preview of the next one from `MishkaPay.preview_subscription_change/1`. A guarded_struct the
  provider fills in.

    * `:id`: the provider's id (`in_...` at Stripe); `:subscription_id`: whose bill.
    * `:status`: `:draft`, `:open` (waiting to be paid), `:paid`, `:uncollectible` or `:void`.
    * `:amount_due`, `:amount_paid`: what it asks and what was paid, as `Money`; `:total`, all of
      it after discounts and tax; `:amount_tax`, the tax in it.
    * `:lines`: what it bills, each a `MishkaPay.Invoice.Lines` (see below).
    * `:customer_id`: who it bills.
    * `:period_start`, `:period_end`: the period it bills.
    * `:hosted_url`, `:pdf_url`: the provider's page and PDF of the bill, for the buyer.
    * `:payment_id`: the payment that paid it, when the provider names one.
    * `:number`: the bill's number once finalized; `:collection`: `:charge_automatically` or
      `:send_invoice`; `:due_at`: when a sent bill is due; `:description`; `:reference`: the
      caller's own id from `MishkaPay.Invoice.Draft`.
    * `:created_at`: when the provider made it.

  ## Lines

  Each of `:lines` is a `MishkaPay.Invoice.Lines`, a sub_field of this struct: what the bill
  charges, how much and for which period. `:id` (`il_...` at Stripe) names it in a credit note's
  lines (`MishkaPay.CreditNote`); `:description`, `:amount` (below zero for a credit),
  `:quantity`, `:price_id`, `:period_start` and `:period_end`. A line with `proration: true` is
  the credit for time not used on the old plan, or the charge for the rest of the period on the
  new one, after a `MishkaPay.change_subscription/1`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :subscription_id, String.t(), derives: "validate(string)"

    field :status, atom(), derives: "validate(enum=Atom[draft::open::paid::uncollectible::void])"

    field :amount_due, Money.t(), validator: {MishkaPay.Money, :field}
    field :amount_paid, Money.t(), validator: {MishkaPay.Money, :field}
    field :total, Money.t(), validator: {MishkaPay.Money, :field}
    field :amount_tax, Money.t(), validator: {MishkaPay.Money, :field}

    sub_field :lines, [MishkaPay.Invoice.Lines.t()],
      structs: true,
      default: [],
      authorized_fields: true,
      derives: "validate(list)" do
      field :id, String.t(), derives: "validate(string)"
      field :description, String.t(), derives: "validate(string)"
      field :amount, Money.t(), validator: {MishkaPay.Money, :signed_field}
      field :quantity, non_neg_integer(), derives: "validate(integer)"
      field :price_id, String.t(), derives: "validate(string)"
      field :proration, boolean(), default: false, derives: "validate(boolean)"
      field :period_start, DateTime.t(), derives: "validate(struct)"
      field :period_end, DateTime.t(), derives: "validate(struct)"
    end

    field :customer_id, String.t(), derives: "validate(string)"
    field :period_start, DateTime.t(), derives: "validate(struct)"
    field :period_end, DateTime.t(), derives: "validate(struct)"
    field :hosted_url, String.t(), derives: "validate(string)"
    field :pdf_url, String.t(), derives: "validate(string)"
    field :payment_id, String.t(), derives: "validate(string)"
    field :number, String.t(), derives: "validate(string)"

    field :collection, :charge_automatically | :send_invoice,
      derives: "validate(enum=Atom[charge_automatically::send_invoice])"

    field :due_at, DateTime.t(), derives: "validate(struct)"
    field :description, String.t(), derives: "validate(string)"
    field :reference, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"

    sub_field :draft, struct(),
      authorized_fields: true,
      main_validator: {__MODULE__, :consistent},
      doc: """
      A bill to make for a customer, outside any subscription, with `MishkaPay.create_invoice/1`: a
      service sold by hand, an order paid later. The provider makes it as a draft and answers it as a
      `MishkaPay.Invoice`; `MishkaPay.finalize_invoice/3` opens it for payment,
      `MishkaPay.send_invoice/3` emails it, and `MishkaPay.pay_invoice/4`, `void_invoice/3`,
      `mark_invoice_uncollectible/3` and `delete_invoice/3` end it. A guarded_struct.

        * `:provider`, `:tenant`: as for a checkout.
        * `:customer_id`: the provider customer it bills (`MishkaPay.create_customer/1`).
        * `:items`: one or more `MishkaPay.Price`, all in one currency: a catalog price by its `:id`,
          or a `:name` with an `:amount` and a `:quantity`. A recurring price is refused: a plan
          starts with a checkout. An item's `:tax_rate_ids` add the seller's own tax rates to it.
        * `:tax_rate_ids`: the seller's own tax rates (`MishkaPay.TaxRate`) for every line of the bill
          that names none of its own.
        * `:collection`: `:charge_automatically` (the default) charges the customer's saved payment
          method when it is finalized; `:send_invoice` emails a bill they pay on the provider's page,
          within `:days_until_due` (30 unless given).
        * `:description`, `:footer`: text on the bill.
        * `:reference`: the caller's own id for the bill, such as an order id; it makes the
          idempotency key, so the same reference never makes two bills, and it comes back on it.
        * `:metadata`: extra pairs kept with it.

      Stripe sells as merchant of record (Managed Payments) only through checkouts and payment links:
      a site with merchant of record on cannot send one-off bills.
      """ do
      field :provider, String.t(),
        enforce: true,
        derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

      field :tenant, term()

      field :customer_id, String.t(),
        enforce: true,
        derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

      field :items, list(),
        enforce: true,
        structs: MishkaPay.Price,
        derives: "validate(not_nil_value, list)"

      field :collection, :charge_automatically | :send_invoice,
        default: :charge_automatically,
        derives: "validate(not_nil_value, enum=Atom[charge_automatically::send_invoice])",
        validator: {__MODULE__, :collection}

      field :days_until_due, pos_integer(), derives: "validate(integer, min_len=1)"

      field :tax_rate_ids, list(),
        derives: "sanitize(each=[trim]) validate(list, each=[string, not_empty])"

      field :description, String.t(), derives: "sanitize(trim) validate(string, max_len=1500)"
      field :footer, String.t(), derives: "sanitize(trim) validate(string, max_len=5000)"

      field :reference, String.t(),
        derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

      dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
    end

    sub_field :item, struct(),
      authorized_fields: true,
      main_validator: {__MODULE__, :charges},
      doc: """
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
      """ do
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

      field :tax_rate_ids, list(),
        derives: "sanitize(each=[trim]) validate(list, each=[string, not_empty])"

      field :total, Money.t(), validator: {MishkaPay.Money, :signed_field}
      field :period_start, DateTime.t(), derives: "validate(struct)"
      field :period_end, DateTime.t(), derives: "validate(struct)"

      field :reference, String.t(),
        derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

      dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
      field :created_at, DateTime.t(), derives: "validate(struct)"
    end
  end

  @doc false
  def collection(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(charge_automatically send_invoice)a)

  # Items in one currency, none recurring; days to pay only for a bill that is sent. It runs on
  # the caller's map, before the fields are built.
  @doc false
  def consistent(attrs) do
    items = List.wrap(key(attrs, :items))

    cond do
      items == [] ->
        invalid(:items, :items_empty)

      Enum.any?(items, &(not is_nil(key(&1, :interval)))) ->
        invalid(:items, :items_one_time)

      items |> MapSet.new(&currency/1) |> MapSet.delete(nil) |> MapSet.size() > 1 ->
        invalid(:items, :items_currency)

      to_string(key(attrs, :collection) || :charge_automatically) == "charge_automatically" and
          not is_nil(key(attrs, :days_until_due)) ->
        invalid(:days_until_due, :due_sent_only)

      true ->
        {:ok, attrs}
    end
  end

  defp invalid(field, message),
    do: {:error, %{field: field, action: :invoice, message: MishkaPay.Messages.text(message)}}

  defp currency(item) do
    case MishkaPay.Money.field(:amount, key(item, :amount)) do
      {:ok, :amount, %Money{currency: currency}} -> currency
      _no_money -> nil
    end
  end

  defp key(%{} = map, name), do: Map.get(map, name) || Map.get(map, Atom.to_string(name))
  defp key(_not_a_map, _name), do: nil

  @doc """
  What a new `MishkaPay.Invoice.Item` charges, as a `MishkaPay.Price` (its catalog price, or its
  name, amount and quantity): the line a provider's bill takes.
  """
  @spec item_price(MishkaPay.Invoice.Item.t()) :: MishkaPay.Price.t()
  def item_price(%MishkaPay.Invoice.Item{} = item) do
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
end

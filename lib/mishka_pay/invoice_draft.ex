# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.InvoiceDraft do
  @moduledoc """
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
  """

  use GuardedStruct

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :consistent} do
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
    field :tax_rate_ids, list(), validator: {MishkaPay.TaxRate, :ids}
    field :description, String.t(), derives: "sanitize(trim) validate(string, max_len=1500)"
    field :footer, String.t(), derives: "sanitize(trim) validate(string, max_len=5000)"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
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
end

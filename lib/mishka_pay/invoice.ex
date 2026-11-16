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
    * `:lines`: what it bills, each a `MishkaPay.InvoiceLine` (prorations say so).
    * `:customer_id`: who it bills.
    * `:period_start`, `:period_end`: the period it bills.
    * `:hosted_url`, `:pdf_url`: the provider's page and PDF of the bill, for the buyer.
    * `:payment_id`: the payment that paid it, when the provider names one.
    * `:created_at`: when the provider made it.
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
    field :lines, list(), structs: MishkaPay.InvoiceLine, default: []
    field :customer_id, String.t(), derives: "validate(string)"
    field :period_start, DateTime.t(), derives: "validate(struct)"
    field :period_end, DateTime.t(), derives: "validate(struct)"
    field :hosted_url, String.t(), derives: "validate(string)"
    field :pdf_url, String.t(), derives: "validate(string)"
    field :payment_id, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

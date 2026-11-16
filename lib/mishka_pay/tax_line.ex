# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.TaxLine do
  @moduledoc """
  One line of a `MishkaPay.TaxCalculation`: what is sold, for how much in all, and the tax the
  provider counted on it. A guarded_struct.

  What the caller gives:

    * `:reference`: the caller's own name for the line, such as a SKU or an order line id; one
      per line, unique within the calculation. It comes back on the line and in the provider's
      tax reports.
    * `:amount`: what the whole line costs, the unit price times `:quantity`, as `Money` (or
      `%{amount: "30.00", currency: "EUR"}`).
    * `:quantity`: how many, 1 by default.
    * `:tax_code`: the provider's tax category of what is sold (Stripe's `"txcd_10302000"` for
      an e-book); the provider's default category when left out.
    * `:tax_behavior`: `:exclusive` (the default: tax is added on top) or `:inclusive` (the
      amount already holds it).
    * `:product_id`: a catalog product whose tax category is used when `:tax_code` is left out.

  What the provider fills in: `:id` and `:amount_tax`, the tax on the line.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :reference, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty, max_len=500)"

    field :amount, Money.t(), enforce: true, validator: {MishkaPay.Money, :field}

    field :quantity, pos_integer(),
      default: 1,
      derives: "validate(not_nil_value, integer, min_len=1)"

    field :tax_code, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=100)"

    field :tax_behavior, :inclusive | :exclusive,
      derives: "validate(enum=Atom[inclusive::exclusive])",
      validator: {MishkaPay.Price, :tax_behavior}

    field :product_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :id, String.t(), derives: "validate(string)"
    field :amount_tax, Money.t(), validator: {MishkaPay.Money, :field}
  end
end

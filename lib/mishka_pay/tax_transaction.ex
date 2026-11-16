# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.TaxTransaction do
  @moduledoc """
  A sale reported to the provider's tax records from a `MishkaPay.TaxCalculation`, with
  `MishkaPay.record_tax/4`: the provider then counts its tax in the site's tax reports and
  filings. A guarded_struct the provider fills in.

    * `:provider`, `:id` (`tax_...` at Stripe).
    * `:reference`: the caller's own id of the sale, such as an order id; one sale per reference.
    * `:calculation_id`: the calculation it was made from.
    * `:customer_id`: the provider customer, when the calculation named one.
    * `:posted_at`: when the tax counts as owed; `:created_at`: when the provider made it.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "validate(string)"
    field :id, String.t(), derives: "validate(string)"
    field :reference, String.t(), derives: "validate(string)"
    field :calculation_id, String.t(), derives: "validate(string)"
    field :customer_id, String.t(), derives: "validate(string)"
    field :posted_at, DateTime.t(), derives: "validate(struct)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

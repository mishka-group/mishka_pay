# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.InvoiceLine do
  @moduledoc """
  One line of a `MishkaPay.Invoice`: what it bills, how much and for which period. A
  guarded_struct the provider fills in. A line with `proration: true` is the credit for time not
  used on the old plan, or the charge for the rest of the period on the new one, after a
  `MishkaPay.change_subscription/1`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :description, String.t(), derives: "validate(string)"
    field :amount, Money.t(), validator: {MishkaPay.Money, :signed_field}
    field :quantity, non_neg_integer(), derives: "validate(integer)"
    field :price_id, String.t(), derives: "validate(string)"
    field :proration, boolean(), default: false, derives: "validate(boolean)"
    field :period_start, DateTime.t(), derives: "validate(struct)"
    field :period_end, DateTime.t(), derives: "validate(struct)"
  end
end

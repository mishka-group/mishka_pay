# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.BalanceTransaction do
  @moduledoc """
  One movement of the seller's balance at the provider: a charge, a refund, a fee, a payout.
  Listed with `MishkaPay.list_balance_transactions/3`, such as every one a payout paid out. A
  guarded_struct the provider fills in.

    * `:provider`, `:id`: the provider's id of it (`txn_...` at Stripe).
    * `:amount`: what moved, before fees; below zero when money left the balance.
    * `:fee`: what the provider kept.
    * `:net`: what the balance changed by, `:amount` less `:fee`.
    * `:type`: the provider's own name for it, such as `"charge"`, `"refund"` or `"payout"`.
    * `:source_id`: the provider object it came from, such as a charge or a refund.
    * `:status`: `:available` or `:pending`.
    * `:description`, `:available_at` (when its money is available), `:created_at`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "validate(string)"
    field :id, String.t(), derives: "validate(string)"
    field :amount, Money.t(), validator: {MishkaPay.Money, :signed_field}
    field :fee, Money.t(), validator: {MishkaPay.Money, :signed_field}
    field :net, Money.t(), validator: {MishkaPay.Money, :signed_field}
    field :type, String.t(), derives: "validate(string)"
    field :source_id, String.t(), derives: "validate(string)"
    field :status, :available | :pending, derives: "validate(enum=Atom[available::pending])"
    field :description, String.t(), derives: "validate(string)"
    field :available_at, DateTime.t(), derives: "validate(struct)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

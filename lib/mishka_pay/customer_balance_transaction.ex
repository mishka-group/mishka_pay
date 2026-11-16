# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.CustomerBalanceTransaction do
  @moduledoc """
  One change of a customer's balance at the provider: store credit given, a debit added, or
  credit used on a bill. Made with `MishkaPay.adjust_customer_balance/5` and listed with
  `MishkaPay.list_customer_balance/4`. A guarded_struct.

  The sign is the provider's: below zero is credit, money the seller owes the customer, taken off
  their next bills; above zero is a debit added to their next bill. At Stripe a customer's
  balance is in one currency.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:customer_id`: the provider customer.
    * `:amount`: a `Money`, below zero to give credit.
    * `:description`: why, for the seller and the customer.
    * `:reference`: the caller's own id for this change, such as a support ticket. It makes the
      idempotency key, so the same reference never changes the balance twice, and it comes back
      on it.

  What the provider fills in: `:id` (`cbtxn_...` at Stripe), `:ending_balance` (the balance after
  it), `:type` (its own name for it, such as `"adjustment"` or `"applied_to_invoice"`),
  `:invoice_id` when a bill used it, and `:created_at`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :customer_id, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :amount, Money.t(), enforce: true, validator: {MishkaPay.Money, :signed_field}

    field :description, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=350)"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    field :id, String.t(), derives: "validate(string)"
    field :ending_balance, Money.t(), validator: {MishkaPay.Money, :signed_field}
    field :type, String.t(), derives: "validate(string)"
    field :invoice_id, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

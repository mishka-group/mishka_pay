# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Refund do
  @moduledoc """
  Money given back on a payment, in full or in part, made with `MishkaPay.refund/1`. A
  guarded_struct.

  What the caller gives:

    * `:provider`, `:tenant`: as for a checkout.
    * `:payment_id`: the payment to refund.
    * `:amount`: how much, a `Money`; left out, the whole payment.
    * `:reason`: `:requested_by_customer`, `:duplicate` or `:fraudulent`.
    * `:reference`: the caller's own id for this refund; it makes the idempotency key, so the same
      reference never refunds twice.

  What the provider fills in: `:id`, `:status` (`:pending`, `:succeeded`, `:failed`, `:canceled`,
  `:requires_action`) and `:created_at`, and `:amount` when it was left out.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :payment_id, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :amount, Money.t(), validator: {MishkaPay.Money, :field}

    field :reason, atom(),
      derives: "validate(enum=Atom[requested_by_customer::duplicate::fraudulent])"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    field :id, String.t(), derives: "validate(string)"

    field :status, atom(),
      derives: "validate(enum=Atom[pending::succeeded::failed::canceled::requires_action])"

    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

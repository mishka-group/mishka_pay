# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Payment do
  @moduledoc """
  One payment as the provider sees it, read with `MishkaPay.fetch_payment/3`. A guarded_struct the
  provider fills in; the provider is the source of truth, so read it again rather than keep it.

    * `:id`: the provider's id (`pi_...` at Stripe).
    * `:amount`: what was asked, a `Money`; `:amount_refunded`: what went back so far.
    * `:status`: `:pending` (not paid yet), `:requires_action` (the buyer must do something, such
      as 3-D Secure), `:paid`, `:partially_refunded`, `:refunded`, `:failed` or `:canceled`.
    * `:reference`: the caller's own id given at checkout.
    * `:customer_id`: the provider's id of the buyer, when it has one.
    * `:created_at`: when the provider made it, a `DateTime`.
  """

  use GuardedStruct

  @statuses "Atom[pending::requires_action::paid::partially_refunded::refunded::failed::canceled]"

  guardedstruct authorized_fields: true do
    field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :amount, Money.t(), enforce: true, validator: {MishkaPay.Money, :field}
    field :amount_refunded, Money.t(), validator: {MishkaPay.Money, :field}
    field :status, atom(), enforce: true, derives: "validate(not_nil_value, enum=#{@statuses})"
    field :reference, String.t(), derives: "validate(string)"
    field :customer_id, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

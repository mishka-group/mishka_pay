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
    * `:customer_id`, `:customer_email`, `:customer_name`: the buyer, as far as the provider knows
      them.
    * `:description`: the provider's description of the payment; `:metadata`: the extra pairs
      kept with it (Mishka Pay's own reference left out).
    * `:payment_method`: how it was paid, such as `"card"`; for a card, `:card_brand` (`"visa"`)
      and `:card_last4`.
    * `:receipt_url`: the provider's receipt page for the buyer, once paid.
    * `:failure_code`, `:failure_message`: why the last try failed, such as `"insufficient_funds"`.
    * `:refunds`: every `MishkaPay.Refund` made on it, newest first.
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
    field :customer_email, String.t(), derives: "validate(string)"
    field :customer_name, String.t(), derives: "validate(string)"
    field :description, String.t(), derives: "validate(string)"
    dynamic_field :metadata
    field :payment_method, String.t(), derives: "validate(string)"
    field :card_brand, String.t(), derives: "validate(string)"
    field :card_last4, String.t(), derives: "validate(string)"
    field :receipt_url, String.t(), derives: "validate(string)"
    field :failure_code, String.t(), derives: "validate(string)"
    field :failure_message, String.t(), derives: "validate(string)"
    field :refunds, list(), structs: MishkaPay.Refund, default: []
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

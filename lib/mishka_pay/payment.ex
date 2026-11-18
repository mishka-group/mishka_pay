# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Payment do
  @moduledoc """
  One payment as the provider sees it, read with `MishkaPay.fetch_payment/3`. A guarded_struct the
  provider fills in; the provider is the source of truth, so read it again rather than keep it.

    * `:id`: the provider's id (`pi_...` at Stripe).
    * `:amount`: what was asked, a `Money`; `:amount_refunded`: what went back so far.
    * `:amount_captured`: what the provider took, once paid; less than `:amount` when a held
      payment was captured in part (`MishkaPay.capture_payment/4`).
    * `:status`: `:pending` (not paid yet), `:requires_action` (the buyer must do something, such
      as 3-D Secure), `:authorized` (the money is held on the card and waits for
      `MishkaPay.capture_payment/4` or `MishkaPay.cancel_payment/3`), `:paid`,
      `:partially_refunded`, `:refunded`, `:failed` or `:canceled`.
    * `:reference`: the caller's own id given at checkout; `:owner`: who the sale is for, as the
      checkout named them (`MishkaPay.Checkout`).
    * `:customer_id`, `:customer_email`, `:customer_name`: the buyer, as far as the provider knows
      them.
    * `:description`: the provider's description of the payment; `:metadata`: the extra pairs
      kept with it (Mishka Pay's own reference left out).
    * `:payment_method`: how it was paid, such as `"card"`; for a card, `:card_brand` (`"visa"`)
      and `:card_last4`.
    * `:receipt_url`: the provider's receipt page for the buyer, once paid.
    * `:failure_code`, `:failure_message`: why the last try failed, such as `"insufficient_funds"`.
    * `:disputed`: the buyer's bank has asked for it back (`MishkaPay.Dispute`).
    * `:refunds`: every `MishkaPay.Refund` made on it, newest first.
    * `:checkout_id`, `:items`: the checkout that took it and what it sold, each a
      `MishkaPay.Price` with its provider `:id`, `:product_id`, `:name`, unit `:amount` and
      `:quantity`; what a shop delivers. Read by `MishkaPay.fetch_payment/3`; a payment made
      outside a checkout (a subscription's renewal, a bill) has none, and `list_payments/3` leaves
      them out.
    * `:created_at`: when the provider made it, a `DateTime`.
  """

  use GuardedStruct

  @statuses "Atom[pending::requires_action::authorized::paid::partially_refunded::refunded::failed::canceled]"

  guardedstruct authorized_fields: true do
    field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :amount, Money.t(), enforce: true, validator: {MishkaPay.Money, :field}
    field :amount_refunded, Money.t(), validator: {MishkaPay.Money, :field}
    field :amount_captured, Money.t(), validator: {MishkaPay.Money, :field}
    field :status, atom(), enforce: true, derives: "validate(not_nil_value, enum=#{@statuses})"
    field :reference, String.t(), derives: "validate(string)"
    field :owner, String.t(), derives: "validate(string)"
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
    field :disputed, boolean(), default: false, derives: "validate(boolean)"
    field :refunds, list(), structs: MishkaPay.Refund, default: []
    field :checkout_id, String.t(), derives: "validate(string)"
    field :items, list(), structs: MishkaPay.Price, default: []
    field :created_at, DateTime.t(), derives: "validate(struct)"

    sub_field :fraud_review, struct(),
      authorized_fields: true,
      doc: """
      A payment the provider's fraud rules held for the seller to look at before it goes on (a
      review, `prv_...` at Stripe Radar). A guarded_struct the provider fills in, read with
      `MishkaPay.fetch_fraud_review/3` and `MishkaPay.list_fraud_reviews/3`, and let through with
      `MishkaPay.approve_fraud_review/3`. Refunding the payment closes it the other way.

        * `:id`, `:payment_id`, `:charge_id`: the review and the payment it holds.
        * `:open`: whether it still waits for the seller.
        * `:opened_reason`: `:rule` (a fraud rule placed it) or `:manual` (someone did).
        * `:reason`: why it is open or how it closed, in the provider's words (`"rule"`,
          `"manual"`, `"approved"`, `"refunded"`, `"refunded_as_fraud"`, `"disputed"`,
          `"redacted"`...); `:closed_reason` only how it closed.
        * `:ip_address`: where the buyer paid from, when the provider knows.
        * `:created_at`.
      """ do
      field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
      field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
      field :payment_id, String.t(), derives: "validate(string)"
      field :charge_id, String.t(), derives: "validate(string)"
      field :open, boolean(), default: false, derives: "validate(boolean)"
      field :opened_reason, :rule | :manual, derives: "validate(enum=Atom[rule::manual])"
      field :reason, String.t(), derives: "validate(string)"
      field :closed_reason, String.t(), derives: "validate(string)"
      field :ip_address, String.t(), derives: "validate(string)"
      field :created_at, DateTime.t(), derives: "validate(struct)"
    end

    sub_field :fraud_warning, struct(),
      authorized_fields: true,
      doc: """
      A card issuer's early warning that a payment looks like fraud (an early fraud warning,
      `issfr_...` at Stripe Radar), often days before the buyer's bank opens a dispute. A guarded_struct
      the provider fills in, read with `MishkaPay.fetch_fraud_warning/3` and
      `MishkaPay.list_fraud_warnings/3`.

        * `:id`, `:payment_id`, `:charge_id`: the warning and the payment it is about.
        * `:fraud_type`: the issuer's kind of fraud, in the provider's words
          (`"made_with_stolen_card"`, `"unauthorized_use_of_card"`, `"card_never_received"`...).
        * `:actionable`: whether a refund can still head off a dispute: the payment is not refunded
          or disputed yet. Refunding an actionable warning's payment in full usually stops the
          dispute and its fee.
        * `:created_at`.
      """ do
      field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
      field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
      field :payment_id, String.t(), derives: "validate(string)"
      field :charge_id, String.t(), derives: "validate(string)"
      field :fraud_type, String.t(), derives: "validate(string)"
      field :actionable, boolean(), default: false, derives: "validate(boolean)"
      field :created_at, DateTime.t(), derives: "validate(struct)"
    end
  end
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.FraudReview do
  @moduledoc """
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
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
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
end

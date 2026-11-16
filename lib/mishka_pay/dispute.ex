# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Dispute do
  @moduledoc """
  A buyer's bank asking for a payment back (a chargeback, `dp_...` at Stripe). A guarded_struct
  the provider fills in, read with `MishkaPay.fetch_dispute/3` and `MishkaPay.list_disputes/3`;
  answered with evidence (`MishkaPay.update_dispute/1`) or accepted (`MishkaPay.accept_dispute/3`).
  A file seller usually takes back what the payment gave while a dispute is open.

    * `:id`, `:payment_id`, `:charge_id`: the dispute and the payment it takes back.
    * `:amount`: how much, as `Money`.
    * `:status`: `:warning_needs_response`, `:warning_under_review`, `:warning_closed` (an
      inquiry before a dispute), `:needs_response`, `:under_review`, `:won`, `:lost` or
      `:prevented`.
    * `:reason`: the bank's reason, in the provider's words (`"fraudulent"`,
      `"product_not_received"`...).
    * `:evidence_due_by`: the last moment to answer; `:has_evidence`, `:submission_count`: what
      was sent so far.
    * `:refundable`: whether the payment can still be refunded instead.
    * `:metadata`, `:created_at`.
  """

  use GuardedStruct

  @statuses "Atom[warning_needs_response::warning_under_review::warning_closed::needs_response::under_review::won::lost::prevented]"

  guardedstruct authorized_fields: true do
    field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
    field :tenant, term()
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :payment_id, String.t(), derives: "validate(string)"
    field :charge_id, String.t(), derives: "validate(string)"
    field :amount, Money.t(), validator: {MishkaPay.Money, :field}
    field :status, atom(), derives: "validate(enum=#{@statuses})"
    field :reason, String.t(), derives: "validate(string)"
    field :evidence_due_by, DateTime.t(), derives: "validate(struct)"
    field :has_evidence, boolean(), default: false, derives: "validate(boolean)"
    field :submission_count, non_neg_integer(), default: 0, derives: "validate(integer)"
    field :refundable, boolean(), derives: "validate(boolean)"
    dynamic_field :metadata
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  @doc "The statuses a dispute can have, as atoms."
  @spec statuses() :: [atom()]
  def statuses,
    do: [
      :warning_needs_response,
      :warning_under_review,
      :warning_closed,
      :needs_response,
      :under_review,
      :won,
      :lost,
      :prevented
    ]
end

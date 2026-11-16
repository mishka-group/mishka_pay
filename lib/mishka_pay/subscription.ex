# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Subscription do
  @moduledoc """
  One subscription as the provider sees it, read with `MishkaPay.fetch_subscription/3`. A
  guarded_struct the provider fills in; the provider is the source of truth, so read it again
  rather than keep it.

    * `:id`: the provider's id (`sub_...` at Stripe).
    * `:status`: `:incomplete` (the first payment is not done), `:incomplete_expired` (it never
      was), `:trialing`, `:active`, `:past_due` (a renewal failed and is being tried again),
      `:unpaid` (the tries ran out), `:paused` or `:canceled`.
    * `:items`: what it charges for, each a `MishkaPay.Price` with its `:interval`.
    * `:customer_id`, `:customer_email`, `:customer_name`: the buyer.
    * `:current_period_start`, `:current_period_end`: the period paid for now.
    * `:cancel_at_period_end`: `true` when it ends at `:current_period_end` (see
      `MishkaPay.cancel_subscription/4`); `:cancel_at`, `:canceled_at`: when it ends, or ended.
    * `:trial_end`: when the trial ends, for one in trial.
    * `:latest_invoice_id`: its newest invoice (`MishkaPay.list_invoices/3` lists them all).
    * `:reference`, `:metadata`: the caller's own id from the checkout, and extra pairs.
    * `:created_at`: when the provider made it.
  """

  use GuardedStruct

  @statuses "Atom[incomplete::incomplete_expired::trialing::active::past_due::unpaid::paused::canceled]"

  guardedstruct authorized_fields: true do
    field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :status, atom(), enforce: true, derives: "validate(not_nil_value, enum=#{@statuses})"
    field :items, list(), structs: MishkaPay.Price, default: []
    field :customer_id, String.t(), derives: "validate(string)"
    field :customer_email, String.t(), derives: "validate(string)"
    field :customer_name, String.t(), derives: "validate(string)"
    field :current_period_start, DateTime.t(), derives: "validate(struct)"
    field :current_period_end, DateTime.t(), derives: "validate(struct)"
    field :cancel_at_period_end, boolean(), default: false, derives: "validate(boolean)"
    field :cancel_at, DateTime.t(), derives: "validate(struct)"
    field :canceled_at, DateTime.t(), derives: "validate(struct)"
    field :trial_end, DateTime.t(), derives: "validate(struct)"
    field :latest_invoice_id, String.t(), derives: "validate(string)"
    field :reference, String.t(), derives: "validate(string)"
    dynamic_field :metadata
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

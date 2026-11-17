# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Transfer do
  @moduledoc """
  Money the platform sends from its own balance to a seller's connected account (a transfer,
  `tr_...` at Stripe): the seller's share of a sale the platform took, or any payment to them.
  Made with `MishkaPay.create_transfer/1`, read with `MishkaPay.fetch_transfer/3` and
  `MishkaPay.list_transfers/3`, and taken back, all or part, with `MishkaPay.reverse_transfer/4`.
  A guarded_struct.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with the platform's keys.
    * `:amount`: how much, as money (`%{amount: "12.00", currency: "USD"}`), above zero, in a
      currency the platform's balance holds.
    * `:destination`: the connected account it goes to (`acct_...`).
    * `:reference`: the host's own id for it, required: it makes the idempotency key, so the
      same reference never sends the money twice, and it comes back on every read.
    * `:source_charge_id`: the sale it pays out of (a charge, `ch_...`): the transfer then waits
      for that money to be available instead of the platform's balance.
    * `:transfer_group`: a name tying the payments and transfers of one order together.
    * `:description`, `:metadata`.

  What the provider fills in: `:id`, `:amount_reversed` (what was taken back so far),
  `:reversed` (`true` once all of it was), `:destination_payment_id` (the payment it made on the
  connected account) and `:created_at`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()
    field :id, String.t(), derives: "validate(string)"
    field :amount, Money.t(), validator: {MishkaPay.Refund, :amount}
    field :destination, String.t(), derives: "sanitize(trim) validate(string, not_empty)"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    field :source_charge_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"

    field :transfer_group, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    field :description, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=500)"

    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}

    field :amount_reversed, Money.t(), validator: {MishkaPay.Money, :field}
    field :reversed, boolean(), default: false, derives: "validate(boolean)"
    field :destination_payment_id, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

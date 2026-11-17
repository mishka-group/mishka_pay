# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.ApplicationFee do
  @moduledoc """
  The platform's cut of a sale made for a connected account (an application fee, `fee_...` at
  Stripe): what a checkout's `:application_fee` or `:application_fee_percent` took. Read with
  `MishkaPay.fetch_application_fee/3` and `MishkaPay.list_application_fees/3`, and given back to
  the seller, all or part, with `MishkaPay.refund_application_fee/4`. A guarded_struct the
  provider fills in.

    * `:provider`, `:id`.
    * `:amount`: the fee taken; `:amount_refunded`: what was given back so far; `:refunded`:
      `true` once all of it was.
    * `:account_id`: the connected account that paid it.
    * `:charge_id`: the sale it was taken from.
    * `:created_at`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :amount, Money.t(), validator: {MishkaPay.Money, :field}
    field :amount_refunded, Money.t(), validator: {MishkaPay.Money, :field}
    field :refunded, boolean(), default: false, derives: "validate(boolean)"
    field :account_id, String.t(), derives: "validate(string)"
    field :charge_id, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

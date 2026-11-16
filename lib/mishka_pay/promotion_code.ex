# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.PromotionCode do
  @moduledoc """
  A code a buyer types at the checkout (`SPRING10`) that applies a `MishkaPay.Coupon`, with its own
  limits. A guarded_struct. A checkout lets buyers type codes with `allow_promotion_codes: true`, or
  applies one itself through `discounts` (`MishkaPay.Discount`).

  Made with `MishkaPay.create_promotion_code/1`, read with `MishkaPay.fetch_promotion_code/3` and
  `MishkaPay.list_promotion_codes/3`, turned off or on again with
  `MishkaPay.update_promotion_code/1` (`active: false`).

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:coupon_id`: the coupon it applies.
    * `:code`: what the buyer types; the provider makes one when it is left out.
    * `:active`: whether it can be used now (`true` by default).
    * `:max_redemptions`, `:expires_at`: its own limits, on top of the coupon's.
    * `:first_time_transaction`: only for a buyer's first purchase.
    * `:minimum_amount`: only when the order is at least this `Money`.
    * `:customer_id`: only for this customer.
    * `:metadata`: extra pairs, string keys to string values.

  What the provider fills in: `:id`, `:times_redeemed`, `:created_at`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :coupon_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :code, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=200)"
    field :active, boolean(), derives: "validate(boolean)"
    field :max_redemptions, pos_integer(), derives: "validate(integer, min_len=1)"
    field :expires_at, DateTime.t(), derives: "validate(struct)"
    field :first_time_transaction, boolean(), derives: "validate(boolean)"
    field :minimum_amount, Money.t(), validator: {MishkaPay.Money, :field}
    field :customer_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
    field :times_redeemed, non_neg_integer(), derives: "validate(integer)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

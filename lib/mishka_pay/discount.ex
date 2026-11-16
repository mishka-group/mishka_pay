# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Discount do
  @moduledoc """
  A discount a checkout applies by itself, in its `:discounts`: a coupon (`%{coupon_id: "SPRING"}`)
  or a promotion code (`%{promotion_code_id: "promo_..."}`), one of them. A guarded_struct. To let
  the buyer type a code instead, a checkout sets `allow_promotion_codes: true`; a checkout does one
  or the other.
  """

  use GuardedStruct

  alias MishkaPay.Messages

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :one_of} do
    field :coupon_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :promotion_code_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
  end

  @doc false
  def one_of(attrs) do
    case {is_binary(attrs[:coupon_id]), is_binary(attrs[:promotion_code_id])} do
      {true, false} ->
        {:ok, attrs}

      {false, true} ->
        {:ok, attrs}

      _none_or_both ->
        {:error,
         %{field: :coupon_id, action: :discount, message: Messages.text(:discount_one_of)}}
    end
  end
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Coupon do
  @moduledoc """
  A discount the provider keeps: a percent or an amount off, once, for some months of a
  subscription, or forever. A guarded_struct. Buyers redeem it through a `MishkaPay.PromotionCode`
  they type, or a checkout applies it directly (`MishkaPay.Discount`).

  Made with `MishkaPay.create_coupon/1`, read with `MishkaPay.fetch_coupon/3` and
  `MishkaPay.list_coupons/3`, removed with `MishkaPay.delete_coupon/3` (codes already given keep
  their discount on what they were applied to).

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:id`: optional, the coupon's own id (`"SPRING"`); the provider makes one when it is left out.
    * `:name`: what the buyer sees on the checkout and the invoice.
    * `:percent_off` (more than 0, at most 100) or `:amount_off` (a `Money`): one of them.
    * `:duration`: `:once` (the default), `:repeating` for `:duration_in_months` of a
      subscription, or `:forever`.
    * `:max_redemptions`: how many times it may be used in all.
    * `:redeem_by`: the last moment it may be used.
    * `:metadata`: extra pairs, string keys to string values.

  What the provider fills in: `:valid` (it can still be used), `:times_redeemed`, `:created_at`.
  """

  use GuardedStruct

  alias MishkaPay.Messages

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :consistent} do
    field :provider, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=200)"
    field :name, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=200)"
    field :percent_off, Decimal.t(), validator: {__MODULE__, :percent_off}
    field :amount_off, Money.t(), validator: {MishkaPay.Money, :field}

    field :duration, :once | :repeating | :forever,
      default: :once,
      derives: "validate(not_nil_value, enum=Atom[once::repeating::forever])",
      validator: {__MODULE__, :duration}

    field :duration_in_months, pos_integer(), derives: "validate(integer, min_len=1)"
    field :max_redemptions, pos_integer(), derives: "validate(integer, min_len=1)"
    field :redeem_by, DateTime.t(), derives: "validate(struct)"
    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
    field :valid, boolean(), derives: "validate(boolean)"
    field :times_redeemed, non_neg_integer(), derives: "validate(integer)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  # A percent from a form is a string; it becomes a Decimal here, and its range is checked with
  # the rest of the coupon, so a percent out of range is never taken for a missing one.
  @doc false
  def percent_off(field, value) do
    case decimal(value) do
      {:ok, percent} -> {:ok, field, percent}
      :error -> {:ok, field, value}
    end
  end

  defp decimal(%Decimal{} = value), do: {:ok, value}
  defp decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp decimal(value) when is_float(value), do: {:ok, Decimal.from_float(value)}

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {percent, ""} -> {:ok, percent}
      _not_a_number -> :error
    end
  end

  defp decimal(_other), do: :error

  defp percent_range(%{percent_off: nil} = attrs), do: {:ok, attrs}

  defp percent_range(%{percent_off: %Decimal{} = percent} = attrs) do
    case Decimal.gt?(percent, 0) and not Decimal.gt?(percent, 100) do
      true -> {:ok, attrs}
      false -> error(:percent_off, :percent_off)
    end
  end

  defp percent_range(%{percent_off: _not_a_number}), do: error(:percent_off, :percent_off)
  defp percent_range(attrs), do: {:ok, attrs}

  # A duration from JSON or a form comes as a string.
  @doc false
  def duration(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(once repeating forever))

  # A percent or an amount, not both; months only for a repeating coupon. A coupon read back from
  # the provider (it has an id and a validity) is taken as the provider has it.
  @doc false
  def consistent(%{valid: valid} = attrs) when is_boolean(valid), do: {:ok, attrs}

  def consistent(attrs) do
    with {:ok, attrs} <- one_off(attrs),
         {:ok, attrs} <- percent_range(attrs),
         do: months(attrs)
  end

  defp one_off(attrs) do
    case {is_nil(attrs[:percent_off]), is_nil(attrs[:amount_off])} do
      {false, true} -> {:ok, attrs}
      {true, false} -> {:ok, attrs}
      _none_or_both -> error(:percent_off, :coupon_one_of)
    end
  end

  # Runs before the default `:once` is set, so a missing duration is `:once`.
  defp months(attrs) do
    repeating? = attrs[:duration] in [:repeating, "repeating"]

    case {repeating?, attrs[:duration_in_months]} do
      {true, months} when is_integer(months) -> {:ok, attrs}
      {false, nil} -> {:ok, attrs}
      _mismatch -> error(:duration_in_months, :coupon_months)
    end
  end

  defp error(field, key),
    do: {:error, %{field: field, action: field, message: Messages.text(key)}}
end

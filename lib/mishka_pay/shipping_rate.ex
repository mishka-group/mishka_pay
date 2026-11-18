# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.ShippingRate do
  @moduledoc """
  A way to ship an order and what it costs (`shr_...` at Stripe): kept by the provider with
  `MishkaPay.create_shipping_rate/1` and offered by its id, or given inline on one checkout. The
  buyer picks one on the checkout's page (`MishkaPay.Checkout`'s `:shipping_rates`). A
  guarded_struct.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys (for `create_shipping_rate/1`).
    * `:name`: what the buyer reads, such as "Standard post".
    * `:amount`: what shipping costs for the whole order, as `Money`; zero ships free.
    * `:min_days`, `:max_days`: the delivery estimate, in business days.
    * `:tax_code`: the provider's tax category of shipping (Stripe's `"txcd_92010001"`), and
      `:tax_behavior`, `:exclusive` or `:inclusive`, for a provider that counts the tax.
    * `:metadata`: extra pairs, string keys to string values.
    * `:id`: on a checkout, a rate the provider already keeps; then nothing else is needed.

  What the provider fills in: `:id`, `:active`, `:created_at`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :named_or_known} do
    field :provider, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :name, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=100)"
    field :amount, Money.t(), validator: {MishkaPay.Money, :field}
    field :min_days, pos_integer(), derives: "validate(integer, min_len=1)"
    field :max_days, pos_integer(), derives: "validate(integer, min_len=1)"

    field :tax_code, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=100)"

    field :tax_behavior, :inclusive | :exclusive,
      derives: "validate(enum=Atom[inclusive::exclusive])",
      validator: {MishkaPay.Price, :tax_behavior}

    field :active, boolean(), derives: "validate(boolean)"
    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  # A rate the provider keeps is named by its id; a new one needs its name and its amount, and an
  # estimate that ends after it starts.
  @doc false
  def named_or_known(%{id: id} = attrs) when is_binary(id), do: {:ok, attrs}

  def named_or_known(%{min_days: min, max_days: max})
      when is_integer(min) and is_integer(max) and min > max,
      do: invalid(:max_days, :shipping_days)

  def named_or_known(%{name: name, amount: %Money{}} = attrs) when is_binary(name),
    do: {:ok, attrs}

  def named_or_known(_attrs), do: invalid(:amount, :shipping_needs)

  defp invalid(field, message),
    do: {:error, %{field: field, action: :shipping, message: MishkaPay.Messages.text(message)}}
end

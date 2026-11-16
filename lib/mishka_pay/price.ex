# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Price do
  @moduledoc """
  A price: one line of a checkout (what the buyer pays for, how much and how many), or a price in
  the provider's catalog for a `MishkaPay.Product`. A guarded_struct.

    * `:name`: what the buyer sees, such as "Elixir ebook".
    * `:amount`: the price of one, a `Money` checked by `MishkaPay.Money` (`%{amount: "19.99",
      currency: "USD"}` works too).
    * `:quantity`: 1 by default.
    * `:tax_code`: the provider's tax category of what is sold, such as Stripe's `"txcd_10302000"`
      for a downloaded e-book. A provider that is the merchant of record (Stripe Managed
      Payments) needs it to work out the tax. A price the provider already knows (`:id`) carries
      its own tax code there, so this one is not sent with it.
    * `:id`: the provider's own id of a price it already knows (`price_...` at Stripe). With it,
      the provider's price is used and `:name` and `:amount` may be left out.
    * `:tax_behavior`: `:exclusive` (tax is added on top, as in the US) or `:inclusive` (the
      amount already holds the tax, as in much of Europe); what a provider counting the tax
      (Stripe Tax, Managed Payments) does with the amount.
    * `:interval`, `:interval_count`: a price charged again on a schedule, for a subscription:
      every `:interval_count` (1 by default) `:day`, `:week`, `:month` or `:year`. Left out, the
      price is paid once.

  In the catalog (`MishkaPay.create_price/1`, `MishkaPay.list_prices/3`) a price also has:

    * `:provider`, `:tenant`: which provider's catalog, with whose keys.

    * `:product_id`: the product it sells; with `:amount` it is all a new price needs.
    * `:lookup_key`: the host's own name for it (`"pro-monthly"`), to find it without its id.
    * `:active`: on sale; `MishkaPay.archive_price/3` turns it off (a provider never deletes a
      price that was used).
    * `:metadata`: extra pairs, string keys to string values.
    * `:created_at`: filled in by the provider.

  On a subscription's item (`MishkaPay.Subscription`), `:item_id` is the provider's id of that
  line (`si_...` at Stripe).
  """

  use GuardedStruct

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :named_or_known} do
    field :provider, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :name, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=250)"
    field :amount, Money.t(), validator: {MishkaPay.Money, :field}

    field :tax_code, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=100)"

    field :interval, :day | :week | :month | :year,
      derives: "validate(enum=Atom[day::week::month::year])",
      validator: {__MODULE__, :interval}

    field :interval_count, pos_integer(), derives: "validate(integer, min_len=1)"

    field :tax_behavior, :inclusive | :exclusive,
      derives: "validate(enum=Atom[inclusive::exclusive])",
      validator: {__MODULE__, :tax_behavior}

    field :quantity, pos_integer(),
      default: 1,
      derives: "validate(not_nil_value, integer, min_len=1)"

    field :product_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"

    field :lookup_key, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    field :active, boolean(), derives: "validate(boolean)"
    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
    field :created_at, DateTime.t(), derives: "validate(struct)"
    field :item_id, String.t(), derives: "validate(string)"
  end

  # An interval from JSON or a form comes as a string.
  @doc false
  def interval(:interval, interval) when interval in ["day", "week", "month", "year"],
    do: {:ok, :interval, String.to_existing_atom(interval)}

  def interval(:interval, interval), do: {:ok, :interval, interval}

  @doc false
  def tax_behavior(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(inclusive exclusive))

  @doc false
  def named_or_known(%{id: id} = attrs) when is_binary(id), do: {:ok, attrs}

  def named_or_known(%{name: name, amount: %Money{}} = attrs) when is_binary(name),
    do: {:ok, attrs}

  def named_or_known(%{product_id: product, amount: %Money{}} = attrs) when is_binary(product),
    do: {:ok, attrs}

  def named_or_known(_attrs) do
    {:error,
     %{
       field: :amount,
       action: :price,
       message: MishkaPay.Messages.text(:price_needs)
     }}
  end
end

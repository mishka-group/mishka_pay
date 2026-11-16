# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.SubscriptionChange do
  @moduledoc """
  A change to a running subscription: a new plan, a new quantity (seats), or both, and how the
  provider bills the difference. A guarded_struct, given to `MishkaPay.change_subscription/1` and
  `MishkaPay.preview_subscription_change/1`.

    * `:provider`, `:tenant`, `:subscription_id`: which subscription, with whose keys.
    * `:item_id`: which of its items changes (`si_...` at Stripe, `MishkaPay.Price`'s `:item_id`);
      left out, its only item.
    * `:price_id`: the new plan, a catalog price; left out, the plan stays.
    * `:quantity`: the new quantity; left out, it stays.
    * `:proration`: how the difference is billed: `:create_prorations` (the provider's default:
      credit and charge wait for the next invoice), `:always_invoice` (bill it now) or `:none`
      (no credit, no charge until the next period).
    * `:proration_date`: the moment the difference is counted from; give the one a preview used,
      so the change bills exactly what the preview showed. It goes only with prorations, and not
      with `billing_cycle_anchor: :now` (a new period has nothing to prorate from).
    * `:billing_cycle_anchor`: `:now` starts a new period at once; `:unchanged` (the default)
      keeps the dates.
    * `:payment_behavior`: what happens when charging the difference fails:
      `:allow_incomplete`, `:error_if_incomplete`, `:pending_if_incomplete` or
      `:default_incomplete`; left out, the provider's default.

  Every option left out is the provider's own default.
  """

  use GuardedStruct

  alias MishkaPay.Helpers.Choice
  alias MishkaPay.Messages

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :something} do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :subscription_id, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :item_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :price_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :quantity, pos_integer(), derives: "validate(integer, min_len=1)"

    field :proration, :create_prorations | :always_invoice | :none,
      derives: "validate(enum=Atom[create_prorations::always_invoice::none])",
      validator: {__MODULE__, :proration}

    field :proration_date, DateTime.t(), derives: "validate(struct)"

    field :billing_cycle_anchor, :now | :unchanged,
      derives: "validate(enum=Atom[now::unchanged])",
      validator: {__MODULE__, :anchor}

    field :payment_behavior,
          :allow_incomplete | :error_if_incomplete | :pending_if_incomplete | :default_incomplete,
          derives:
            "validate(enum=Atom[allow_incomplete::error_if_incomplete::pending_if_incomplete::default_incomplete])",
          validator: {__MODULE__, :payment_behavior}
  end

  # Choices from JSON or a form come as strings.
  @doc false
  def proration(field, value),
    do: Choice.atom(field, value, ~w(create_prorations always_invoice none))

  @doc false
  def anchor(field, value), do: Choice.atom(field, value, ~w(now unchanged))

  @doc false
  def payment_behavior(field, value),
    do:
      Choice.atom(
        field,
        value,
        ~w(allow_incomplete error_if_incomplete pending_if_incomplete default_incomplete)
      )

  # A change changes something: the plan, the quantity, or at least starts a new period.
  @doc false
  def something(attrs) do
    case Enum.any?([:price_id, :quantity, :billing_cycle_anchor], &(attrs[&1] not in [nil, ""])) do
      true ->
        dated(attrs)

      false ->
        {:error, %{field: :price_id, action: :change, message: Messages.text(:change_nothing)}}
    end
  end

  # A proration date dates prorations: none with no proration, none with a new period now.
  defp dated(%{proration_date: %DateTime{}} = attrs) do
    case prorates?(attrs) do
      true ->
        {:ok, attrs}

      false ->
        {:error,
         %{field: :proration_date, action: :change, message: Messages.text(:proration_date)}}
    end
  end

  defp dated(attrs), do: {:ok, attrs}

  @doc false
  # Whether the change has prorations a date can count from.
  def prorates?(attrs) do
    attrs[:proration] not in [:none, "none"] and attrs[:billing_cycle_anchor] not in [:now, "now"]
  end
end

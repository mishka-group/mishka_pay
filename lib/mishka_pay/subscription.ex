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
    * `:items`: what it charges for, each a `MishkaPay.Price` with its `:interval`, `:quantity`
      and `:item_id` (the line a `MishkaPay.Subscription.Change` names).
    * `:pause_behavior`, `:resumes_at`: while collection is paused
      (`MishkaPay.pause_collection/4`), what happens to its invoices (`:void`,
      `:keep_as_draft` or `:mark_uncollectible`) and when collection starts again by itself.
    * `:customer_id`, `:customer_email`, `:customer_name`: the buyer.
    * `:current_period_start`, `:current_period_end`: the period paid for now.
    * `:cancel_at_period_end`: `true` when it ends at `:current_period_end` (see
      `MishkaPay.cancel_subscription/4`); `:cancel_at`, `:canceled_at`: when it ends, or ended.
    * `:trial_end`: when the trial ends, for one in trial.
    * `:latest_invoice_id`: its newest invoice (`MishkaPay.list_invoices/3` lists them all).
    * `:default_payment_method`: the payment method its invoices are charged to (`pm_...`), the
      one the buyer paid its checkout with or changed it to; `:card_brand` (`"visa"`) and
      `:card_last4` when that is a card. Empty when it has none of its own and the customer's
      default pays it.
    * `:schedule_id`: the `MishkaPay.Subscription.Schedule` that runs it, when one does.
    * `:reference`, `:metadata`: the caller's own id from the checkout, and extra pairs;
      `:owner`: who it is for, as the checkout named them (`MishkaPay.Checkout`).
    * `:created_at`: when the provider made it.
  """

  use GuardedStruct

  @statuses ~w(incomplete incomplete_expired trialing active past_due unpaid paused canceled)a
  @status_enum "Atom[#{Enum.join(@statuses, "::")}]"

  alias MishkaPay.Helpers.Choice
  alias MishkaPay.Messages

  guardedstruct authorized_fields: true do
    field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :status, atom(), enforce: true, derives: "validate(not_nil_value, enum=#{@status_enum})"
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
    field :default_payment_method, String.t(), derives: "validate(string)"
    field :card_brand, String.t(), derives: "validate(string)"
    field :card_last4, String.t(), derives: "validate(string)"
    field :schedule_id, String.t(), derives: "validate(string)"

    field :pause_behavior, :void | :keep_as_draft | :mark_uncollectible,
      derives: "validate(enum=Atom[void::keep_as_draft::mark_uncollectible])",
      validator: {__MODULE__, :pause_behavior}

    field :resumes_at, DateTime.t(), derives: "validate(struct)"
    field :reference, String.t(), derives: "validate(string)"
    field :owner, String.t(), derives: "validate(string)"
    dynamic_field :metadata
    field :created_at, DateTime.t(), derives: "validate(struct)"

    sub_field :change, struct(),
      authorized_fields: true,
      main_validator: {__MODULE__, :something},
      doc: """
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
      """ do
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
            :allow_incomplete
            | :error_if_incomplete
            | :pending_if_incomplete
            | :default_incomplete,
            derives:
              "validate(enum=Atom[allow_incomplete::error_if_incomplete::pending_if_incomplete::default_incomplete])",
            validator: {__MODULE__, :payment_behavior}
    end

    sub_field :schedule, struct(),
      authorized_fields: true,
      main_validator: {__MODULE__, :planned},
      doc: """
      A plan for a subscription over time, in phases (`MishkaPay.Subscription.Schedule.Phases`): a change of
      plan on a set date, an intro price, a membership that stops after twelve months. Made with
      `MishkaPay.create_subscription_schedule/1`, read with `MishkaPay.fetch_subscription_schedule/3`
      and `MishkaPay.list_subscription_schedules/3`, changed with
      `MishkaPay.update_subscription_schedule/1`, and ended with
      `MishkaPay.release_subscription_schedule/3` (the subscription goes on alone) or
      `MishkaPay.cancel_subscription_schedule/4` (the subscription ends too). A guarded_struct.

      What the caller gives to make one, in one of two ways:

        * from a running subscription: `:subscription_id`, nothing else; its one phase is the
          subscription as it is now, and a change (`update_subscription_schedule/1`) adds the next;
        * new: `:customer_id` and its `:phases`, from `:start_at` (now unless given); the
          subscription starts when the first phase does.

      A new schedule also takes `:billing_mode` (`:flexible`, the default, or `:classic`) and
      `:proration_discounts` (`:itemized`, the default, or `:included`), as a checkout does
      (`MishkaPay.Checkout`); left out, the tenant's own (`MishkaPay.Credentials`) apply. A schedule
      made from a subscription keeps the subscription's billing mode, and a change cannot set one.

      And on either, `:reference` (the caller's own id: it makes the idempotency key, so the same
      reference never makes two) and `:metadata`. A change (`:id` given) names only what it changes:
      `:phases` (all of them from the current one on, the current one with the start it has),
      `:end_behavior`, `:proration` (how the change itself is billed), `:metadata`.

      `:end_behavior` says what happens after the last phase: `:release` (the subscription goes on
      as the last phase left it) or `:cancel` (it ends).

      What the provider fills in: `:id` (`sub_sched_...` at Stripe), `:status` (`:not_started`,
      `:active`, `:completed`, `:released` or `:canceled`), `:subscription_id` (the subscription it
      runs), `:released_subscription_id` (the one it let go), every phase's dates, `:current_phase`
      (the index of the phase running now), and `:created_at`, `:released_at`, `:canceled_at`,
      `:completed_at`.

      ## Phases

      Each of `:phases` is a `MishkaPay.Subscription.Schedule.Phases`, a sub_field of this struct: one
      stretch of the schedule, what the subscription charges, and for how long. Phases follow each
      other; when the last one ends the schedule does what its `:end_behavior` says.

        * `:items`: one or more `MishkaPay.Price`, each a catalog price by `:id` with its
          `:quantity` (1 unless given).
        * How long, one of: `:iterations` periods of `:interval` (`:day`, `:week`, `:month` or
          `:year`; `iterations: 12, interval: :month` is a year), or until `:end_at`. The last phase
          may leave both out: it then runs one period of its prices.
        * `:start_at`: when it starts; only the first phase of a schedule takes one, and a change
          to a running schedule names its current phase with the start it has.
        * `:trial`: `true` makes the whole phase a free trial; `:trial_end_at` ends a trial inside it.
        * `:proration`: how a change of price at the phase's start is billed: `:create_prorations`,
          `:always_invoice` or `:none`.

      The provider fills in `:start_at` and `:end_at` of every phase.
      """ do
      field :provider, String.t(),
        enforce: true,
        derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

      field :tenant, term()
      field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
      field :customer_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
      field :subscription_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
      field :start_at, DateTime.t(), derives: "validate(struct)"

      field :end_behavior, :release | :cancel,
        derives: "validate(enum=Atom[release::cancel])",
        validator: {__MODULE__, :end_behavior}

      sub_field :phases, [MishkaPay.Subscription.Schedule.Phases.t()],
        structs: true,
        authorized_fields: true,
        main_validator: {__MODULE__, :phase_planned},
        derives: "validate(list)" do
        field :items, list(), structs: MishkaPay.Price, derives: "validate(list)"
        field :start_at, DateTime.t(), derives: "validate(struct)"
        field :end_at, DateTime.t(), derives: "validate(struct)"
        field :iterations, pos_integer(), derives: "validate(integer, min_len=1)"

        field :interval, :day | :week | :month | :year,
          derives: "validate(enum=Atom[day::week::month::year])",
          validator: {MishkaPay.Price, :interval}

        field :trial, boolean(), derives: "validate(boolean)"
        field :trial_end_at, DateTime.t(), derives: "validate(struct)"

        field :proration, :create_prorations | :always_invoice | :none,
          derives: "validate(enum=Atom[create_prorations::always_invoice::none])",
          validator: {__MODULE__, :proration}
      end

      field :billing_mode, :flexible | :classic,
        derives: "validate(enum=Atom[flexible::classic])",
        validator: {MishkaPay.Checkout, :billing_mode}

      field :proration_discounts, :itemized | :included,
        derives: "validate(enum=Atom[itemized::included])",
        validator: {MishkaPay.Checkout, :proration_discounts}

      field :proration, :create_prorations | :always_invoice | :none,
        derives: "validate(enum=Atom[create_prorations::always_invoice::none])",
        validator: {__MODULE__, :proration}

      field :reference, String.t(),
        derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

      dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}

      field :status, :not_started | :active | :completed | :released | :canceled,
        derives: "validate(enum=Atom[not_started::active::completed::released::canceled])"

      field :current_phase, non_neg_integer(), derives: "validate(integer)"
      field :released_subscription_id, String.t(), derives: "validate(string)"
      field :created_at, DateTime.t(), derives: "validate(struct)"
      field :released_at, DateTime.t(), derives: "validate(struct)"
      field :canceled_at, DateTime.t(), derives: "validate(struct)"
      field :completed_at, DateTime.t(), derives: "validate(struct)"
    end
  end

  @doc """
  Every status a subscription can be in, as `:status` names them: what
  `MishkaPay.list_subscriptions/3` and `MishkaPay.search_subscriptions/3` filter by.
  """
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  # A provider names the behavior as a string.
  @doc false
  def pause_behavior(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(void keep_as_draft mark_uncollectible)a)

  # Choices from JSON or a form come as strings.
  @doc false
  def proration(field, value),
    do: Choice.atom(field, value, ~w(create_prorations always_invoice none)a)

  @doc false
  def anchor(field, value), do: Choice.atom(field, value, ~w(now unchanged)a)

  @doc false
  def payment_behavior(field, value),
    do:
      Choice.atom(
        field,
        value,
        ~w(allow_incomplete error_if_incomplete pending_if_incomplete default_incomplete)a
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
    case change_prorates?(attrs) do
      true ->
        {:ok, attrs}

      false ->
        {:error,
         %{field: :proration_date, action: :change, message: Messages.text(:proration_date)}}
    end
  end

  defp dated(attrs), do: {:ok, attrs}

  @doc """
  Whether a subscription change makes prorations that a `proration_date` counts from: true unless
  its `proration` is `:none` or its `billing_cycle_anchor` is `:now`.

  Date such a change once and send the same `proration_date` to the preview and to the change, so
  the change bills what the preview showed.
  """
  @spec change_prorates?(map()) :: boolean()
  def change_prorates?(attrs) do
    attrs[:proration] not in [:none, "none"] and attrs[:billing_cycle_anchor] not in [:now, "now"]
  end

  @doc false
  def end_behavior(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(release cancel)a)

  @doc """
  The fields a new schedule cannot go without: none more from a subscription, its customer and
  phases otherwise. `MishkaPay.create_subscription_schedule/1` asks for them once it is built.
  """
  @spec schedule_needs(map()) :: [atom()]
  def schedule_needs(attrs) do
    case key(attrs, :subscription_id) do
      nil -> [:customer_id, :phases]
      _from -> []
    end
  end

  # A new schedule from a subscription takes nothing of its own plan, and phases given, new or in
  # a change, are one or more. The billing mode is set only on a new schedule of its own. A
  # schedule the provider answered (it has a status) is taken as it is. It runs on the caller's
  # map, before the fields are built; a field that failed its own checks is no longer in it.
  @doc false
  def planned(attrs) do
    from = key(attrs, :subscription_id)

    planned =
      Enum.find(
        [:customer_id, :phases, :start_at, :end_behavior, :billing_mode, :proration_discounts],
        &key(attrs, &1)
      )

    billing = Enum.find([:billing_mode, :proration_discounts], &key(attrs, &1))

    case {key(attrs, :status), key(attrs, :id), from, planned} do
      {nil, nil, from, planned} when not is_nil(from) and not is_nil(planned) ->
        invalid(planned, :schedule_from_subscription)

      {nil, id, _from, _planned} when not is_nil(id) and not is_nil(billing) ->
        invalid(billing, :billing_mode_when_made)

      {nil, _new_or_change, _from, _planned} ->
        with {:ok, attrs} <- MishkaPay.Checkout.billing(attrs), do: some_phases(attrs)

      _answered ->
        {:ok, attrs}
    end
  end

  # A phase charges catalog prices by id, for a number of periods of one interval or until a
  # date, not both. It runs on the caller's map, before the fields are built.
  @doc false
  def phase_planned(attrs) do
    items = key(attrs, :items)
    iterations = key(attrs, :iterations)

    cond do
      not is_list(items) or items == [] or Enum.any?(items, &is_nil(key(&1, :id))) ->
        invalid_phase(:items, :phase_prices)

      not is_nil(iterations) and
          (is_nil(key(attrs, :interval)) or not is_nil(key(attrs, :end_at))) ->
        invalid_phase(:iterations, :phase_length)

      true ->
        {:ok, attrs}
    end
  end

  defp invalid_phase(field, message),
    do:
      {:error,
       %{field: field, action: :subscription_phase, message: MishkaPay.Messages.text(message)}}

  defp some_phases(attrs) do
    case key(attrs, :phases) do
      [] -> invalid(:phases, :customer_needs, field: :phases)
      _some_or_none -> {:ok, attrs}
    end
  end

  defp invalid(field, message, bindings \\ []) do
    {:error,
     %{
       field: field,
       action: :subscription_schedule,
       message: MishkaPay.Messages.text(message, bindings)
     }}
  end

  defp key(%{} = map, name), do: Map.get(map, name) || Map.get(map, Atom.to_string(name))
  defp key(_not_a_map, _name), do: nil
end

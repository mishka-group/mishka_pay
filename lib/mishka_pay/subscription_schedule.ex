# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.SubscriptionSchedule do
  @moduledoc """
  A plan for a subscription over time, in phases (`MishkaPay.SubscriptionPhase`): a change of
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
  """

  use GuardedStruct

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :planned} do
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

    field :phases, list(), structs: MishkaPay.SubscriptionPhase, derives: "validate(list)"

    field :proration, :create_prorations | :always_invoice | :none,
      derives: "validate(enum=Atom[create_prorations::always_invoice::none])",
      validator: {MishkaPay.SubscriptionChange, :proration}

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

  @doc false
  def end_behavior(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(release cancel))

  @doc """
  The fields a new schedule cannot go without: none more from a subscription, its customer and
  phases otherwise. `MishkaPay.create_subscription_schedule/1` asks for them once it is built.
  """
  @spec needs(map()) :: [atom()]
  def needs(attrs) do
    case key(attrs, :subscription_id) do
      nil -> [:customer_id, :phases]
      _from -> []
    end
  end

  # A new schedule from a subscription takes nothing of its own plan, and phases given, new or in
  # a change, are one or more. A schedule the provider answered (it has a status) is taken as it
  # is. It runs on the caller's map, before the fields are built; a field that failed its
  # own checks is no longer in it.
  @doc false
  def planned(attrs) do
    from = key(attrs, :subscription_id)
    planned = Enum.find([:customer_id, :phases, :start_at, :end_behavior], &key(attrs, &1))

    case {key(attrs, :status), key(attrs, :id), from, planned} do
      {nil, nil, from, planned} when not is_nil(from) and not is_nil(planned) ->
        invalid(planned, :schedule_from_subscription)

      {nil, _new_or_change, _from, _planned} ->
        some_phases(attrs)

      _answered ->
        {:ok, attrs}
    end
  end

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

  defp key(map, name), do: Map.get(map, name) || Map.get(map, Atom.to_string(name))
end

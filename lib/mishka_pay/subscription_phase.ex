# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.SubscriptionPhase do
  @moduledoc """
  One stretch of a `MishkaPay.SubscriptionSchedule`: what the subscription charges, and for how
  long. Phases follow each other; when the last one ends the schedule does what its
  `:end_behavior` says. A guarded_struct.

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
  """

  use GuardedStruct

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :planned} do
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
      validator: {MishkaPay.SubscriptionChange, :proration}
  end

  # A phase charges catalog prices by id, for a number of periods of one interval or until a
  # date, not both. It runs on the caller's map, before the fields are built.
  @doc false
  def planned(attrs) do
    items = key(attrs, :items)
    iterations = key(attrs, :iterations)

    cond do
      not is_list(items) or items == [] or Enum.any?(items, &is_nil(key(&1, :id))) ->
        invalid(:items, :phase_prices)

      not is_nil(iterations) and
          (is_nil(key(attrs, :interval)) or not is_nil(key(attrs, :end_at))) ->
        invalid(:iterations, :phase_length)

      true ->
        {:ok, attrs}
    end
  end

  defp invalid(field, message),
    do:
      {:error,
       %{field: field, action: :subscription_phase, message: MishkaPay.Messages.text(message)}}

  defp key(%{} = map, name), do: Map.get(map, name) || Map.get(map, Atom.to_string(name))
  defp key(_not_a_map, _name), do: nil
end

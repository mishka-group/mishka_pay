# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Meter do
  @moduledoc """
  A meter counts what customers use, for prices billed by usage (`mtr_...` at Stripe). A
  guarded_struct.

  Made with `MishkaPay.create_meter/1`, listed with `MishkaPay.list_meters/3`, turned off with
  `MishkaPay.deactivate_meter/3` (a provider never deletes one). Usage reaches it with
  `MishkaPay.report_usage/1` under its `:event_name`, and a price bills it with `:meter_id` and an
  `:interval` (`MishkaPay.create_price/1`).

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:name`: the meter's name, for the seller only.
    * `:event_name`: the name usage is reported under, such as `"api_call"`.
    * `:aggregation`: how a period's usage adds up: `:sum` (the default) of the values, `:count`
      of the reports, or the `:last` value reported.

  What the provider fills in: `:id`, `:status` (`:active` or `:inactive`) and `:created_at`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :tenant, term()
    field :id, String.t(), derives: "validate(string)"
    field :name, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=250)"

    field :event_name, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=100)"

    field :aggregation, :sum | :count | :last,
      default: :sum,
      derives: "validate(not_nil_value, enum=Atom[sum::count::last])",
      validator: {__MODULE__, :aggregation}

    field :status, :active | :inactive, derives: "validate(enum=Atom[active::inactive])"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  @doc false
  def aggregation(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(sum count last)a)
end

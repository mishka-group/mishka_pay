# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.UsageCancellation do
  @moduledoc """
  Takes back one usage report sent by mistake, with `MishkaPay.cancel_usage/1`: the meter then
  counts it as if it was never reported. A guarded_struct.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:event_name`: the meter's event name the report was sent under.
    * `:usage_id`: the report's id, the `:id` of the `MishkaPay.Usage` that
      `MishkaPay.report_usage/1` answered (made from its `:reference`).

  What the provider fills in: `:status`, `:pending` while it takes the report out of the count,
  `:complete` once it has.

  A provider takes a report back only for a while after it came in (Stripe: 24 hours). After
  that, report the same value again below zero to correct the count.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :event_name, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty, max_len=100)"

    field :usage_id, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty, max_len=100)"

    field :status, :pending | :complete, derives: "validate(enum=Atom[pending::complete])"
  end
end

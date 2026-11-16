# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.UsageSummary do
  @moduledoc """
  What a meter counted for one customer over a window of time, read with
  `MishkaPay.usage_summary/6`. A guarded_struct the provider fills in.

    * `:provider`, `:meter_id`, `:customer_id`: whose usage, on which meter.
    * `:value`: the usage the meter's aggregation gives for the window (a sum, a count or the
      last value), as the provider reports it; 0 when nothing was reported.
    * `:from`, `:to`: the window the provider counted, `:to` not included. A provider may widen
      the window asked for to its own boundaries, such as whole minutes at Stripe.

  A provider counts usage a little after it is reported, so a report made a moment ago may not
  be in the value yet.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "validate(string)"
    field :meter_id, String.t(), derives: "validate(string)"
    field :customer_id, String.t(), derives: "validate(string)"
    field :value, number(), default: 0
    field :from, DateTime.t(), derives: "validate(struct)"
    field :to, DateTime.t(), derives: "validate(struct)"
  end
end

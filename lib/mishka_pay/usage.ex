# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Usage do
  @moduledoc """
  One report of what a customer used, sent with `MishkaPay.report_usage/1` to the
  `MishkaPay.Meter` that counts its `:event_name`. A price on that meter bills it at the end of
  the period. A guarded_struct.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:event_name`: the meter's event name.
    * `:customer_id`: the provider customer who used it (`MishkaPay.create_customer/1`).
    * `:value`: how much, 1 by default: an integer, a `Decimal` or a number in a string. A
      negative value takes back usage reported by mistake.
    * `:at`: when it was used, a `DateTime`; now when left out.
    * `:reference`: the caller's own id for this use, such as a request id. It makes the
      provider's id of the report and its idempotency key, so the same reference never counts
      twice.
    * `:stream`: `true` sends the report through the provider's path for high volume (Stripe's
      meter event stream, up to 10,000 reports a second in live mode). The provider checks
      such a report after it answers, so a report it cannot count (an unknown customer or event
      name) is not refused in the answer: it comes back later as the provider's error event.
      `false` (the default) sends it the usual way, checked before the answer.

  What the provider fills in: `:id`, its own id of the report.
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

    field :customer_id, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :value, integer() | Decimal.t(), default: 1, validator: {__MODULE__, :value}
    field :at, DateTime.t(), derives: "validate(struct)"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    field :stream, boolean(), default: false, derives: "validate(not_nil_value, boolean)"

    field :id, String.t(), derives: "validate(string)"
  end

  # An exact number: a float is refused, as for money, since `0.1 + 0.2` is not `0.3`.
  @doc false
  def value(field, value) when is_integer(value), do: {:ok, field, value}
  # Infinity and NaN carry an atom as their coefficient.
  def value(field, %Decimal{coef: coef} = value) when is_integer(coef), do: {:ok, field, value}

  def value(field, value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {%Decimal{coef: coef} = decimal, ""} when is_integer(coef) -> {:ok, field, decimal}
      _not_a_number -> not_exact(field)
    end
  end

  def value(field, _other), do: not_exact(field)

  defp not_exact(field), do: {:error, field, MishkaPay.Messages.text(:usage_value)}
end

defmodule MishkaPay.Usage.Summary do
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

defmodule MishkaPay.Usage.Cancellation do
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

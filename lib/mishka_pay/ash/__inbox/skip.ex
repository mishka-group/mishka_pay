# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Inbox.Skip do
    @moduledoc """
    The inbox's `:skip`: a person decides an event that failed, or is still being tried after a
    failed try, is not worth another try. The event becomes `:skipped` and keeps when
    (`skipped_at`), who (`skipped_by_id`, the `:by` argument, any id the host gives) and, when given,
    why (`skip_reason`, the `:reason` argument trimmed and cut to 200 characters). The `:process`
    trigger reads only `:pending` events, so a skipped one is never tried again: a retry its job
    still has planned finds the event no longer applies and is cancelled. Any other event is refused.

    Emits `[:mishka_pay, :inbox, :skipped]` with the event's `:provider`, `:tenant`, `:type` and
    `:event_id`. `:bring_back` (`MishkaPay.Ash.Inbox.BringBack`) undoes it.
    """

    use Ash.Resource.Change

    @reason_max 200

    @impl true
    def change(%{data: row} = changeset, _opts, _context) do
      case skippable?(row) do
        true ->
          :telemetry.execute([:mishka_pay, :inbox, :skipped], %{count: 1}, meta(row))

          Ash.Changeset.force_change_attributes(changeset,
            status: :skipped,
            skipped_at: DateTime.utc_now(),
            skipped_by_id: Ash.Changeset.get_argument(changeset, :by),
            skip_reason: reason(Ash.Changeset.get_argument(changeset, :reason))
          )

        false ->
          Ash.Changeset.add_error(changeset,
            field: :status,
            message: "Only an event that failed, or is still being tried, can be skipped."
          )
      end
    end

    defp skippable?(%{status: :failed}), do: true
    defp skippable?(%{status: :pending, last_error: error}) when is_binary(error), do: true
    defp skippable?(_row), do: false

    defp reason(text) when is_binary(text) do
      case text |> String.trim() |> String.slice(0, @reason_max) do
        "" -> nil
        kept -> kept
      end
    end

    defp reason(_none), do: nil

    @doc false
    def meta(row),
      do: %{provider: row.provider, tenant: row.tenant, type: row.type, event_id: row.event_id}
  end
end

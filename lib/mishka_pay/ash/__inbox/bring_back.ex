# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Inbox.BringBack do
    @moduledoc """
    The inbox's `:bring_back`: undoes a `:skip`. The event is `:failed` again, waiting for a person,
    and its skip fields are emptied; it is not tried again by itself (a host's "run again" is the
    `:process` action). An event that is not skipped is refused.

    Emits `[:mishka_pay, :inbox, :brought_back]` with the event's `:provider`, `:tenant`, `:type` and
    `:event_id`.
    """

    use Ash.Resource.Change

    @impl true
    def change(%{data: %{status: :skipped} = row} = changeset, _opts, _context) do
      :telemetry.execute(
        [:mishka_pay, :inbox, :brought_back],
        %{count: 1},
        MishkaPay.Ash.Inbox.Skip.meta(row)
      )

      Ash.Changeset.force_change_attributes(changeset,
        status: :failed,
        skipped_at: nil,
        skipped_by_id: nil,
        skip_reason: nil
      )
    end

    def change(changeset, _opts, _context),
      do:
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "Only a skipped event can be brought back."
        )
  end
end

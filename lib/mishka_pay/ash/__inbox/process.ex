# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Inbox.Process do
    @moduledoc """
    Works one inbox event: fires `mishka_pay:event:process` with it before the action's
    transaction starts, since the listeners may call the provider, and marks it processed when
    every listener took it. Otherwise the action fails, so its AshOban job tries again.
    """

    use Ash.Resource.Change

    alias MishkaPay.{Event, Events}
    alias MishkaPay.Helpers.Plugins

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_transaction(changeset, fn changeset ->
        timeout = Application.get_env(:mishka_pay, :event_process_timeout, 30_000)

        case Plugins.call(
               Events.event_process(),
               %{event: event(changeset.data), failed: nil},
               timeout
             ) do
          {:ok, %{failed: nil}} ->
            Ash.Changeset.force_change_attributes(changeset,
              status: :processed,
              last_error: nil,
              processed_at: DateTime.utc_now()
            )

          answer ->
            Ash.Changeset.add_error(changeset, "the event was not processed: #{reason(answer)}")
        end
      end)
    end

    defp event(record) do
      %Event{
        provider: record.provider,
        tenant: record.tenant,
        id: record.event_id,
        type: record.type,
        object_id: record.object_id,
        object_type: record.object_type,
        livemode: record.livemode,
        account: record.account,
        created_at: record.provider_created_at
      }
    end

    defp reason({:ok, %{failed: reason}}) when is_binary(reason), do: reason
    defp reason({:ok, %{failed: reason}}), do: inspect(reason)
    defp reason({:ok, _not_an_answer}), do: "invalid_answer"
    defp reason({:error, reason}), do: to_string(reason)
  end
end

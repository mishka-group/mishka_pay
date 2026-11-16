# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Inbox.Process do
    @moduledoc """
    Works one inbox event: fires `mishka_pay:event:process` with it before the action's
    transaction starts, since the listeners may call the provider, and marks it processed when
    every listener took it. Otherwise it keeps the reason in `:last_error` and the action fails, so
    its AshOban job tries again.

    Each try is a span, `[:mishka_pay, :inbox, :process, :start | :stop]`, with the event's
    `:provider`, `:tenant`, `:type` and `:event_id`; `:stop` adds the `:outcome` (`:processed` or
    `:retry`) and the measurement `:lag`, the milliseconds since the event was stored.
    """

    use Ash.Resource.Change

    alias MishkaPay.{Event, Events}
    alias MishkaPay.Helpers.Plugins

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_transaction(changeset, fn changeset ->
        row = changeset.data

        meta = %{
          provider: row.provider,
          tenant: row.tenant,
          type: row.type,
          event_id: row.event_id
        }

        :telemetry.span([:mishka_pay, :inbox, :process], meta, fn ->
          changeset = work(changeset)
          outcome = (changeset.valid? && :processed) || :retry
          {changeset, %{lag: lag(row)}, Map.put(meta, :outcome, outcome)}
        end)
      end)
    end

    defp lag(%{inserted_at: %DateTime{} = at}),
      do: DateTime.diff(DateTime.utc_now(), at, :millisecond)

    defp lag(_row), do: nil

    defp work(changeset) do
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
          message = "the event was not processed: #{reason(answer)}"
          note(changeset.data, message)

          Ash.Changeset.add_error(
            changeset,
            Ash.Error.Changes.InvalidChanges.exception(message: message)
          )
      end
    end

    # Outside the failing action, so the reason stays on the row while AshOban tries again; the row
    # is still :pending, and the last try marks it :failed.
    defp note(record, message) do
      _noted =
        Ash.update(record, %{last_error: String.slice(message, 0, 2_000)},
          action: :note_error,
          authorize?: false
        )

      :ok
    end

    defp event(record) do
      %Event{
        provider: record.provider,
        tenant: record.tenant,
        id: record.event_id,
        type: record.type,
        object_id: record.object_id,
        object_type: record.object_type,
        payment_id: record.payment_id,
        subscription_id: record.subscription_id,
        dispute_id: record.dispute_id,
        customer_id: record.customer_id,
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

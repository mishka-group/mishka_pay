# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Inbox.Answer do
    @moduledoc """
    Makes a module the `mishka_pay:webhook:answered` listener that writes on an inbox row how long
    its webhook took from coming in to its answer (`:answer_ms`) and the status sent
    (`:answer_status`):

        defmodule MyApp.Pay.InboxAnswer do
          use MishkaPay.Ash.Inbox.Answer, resource: MyApp.Pay.WebhookEvent
        end

    `MishkaPay.Ash.Resource` makes one for each inbox that listens, as
    `<Resource>.MishkaPayAnswerListener`, and `MishkaPay.Ash.listeners/1` lists it. It runs after
    the answer went out, in one `UPDATE` of the event's row by its provider and event id (the
    resource's notifiers see it, so an open page shows the time); a refused
    message has no row and is left to the `:webhook_rejection` kind. A row sent again by the
    provider gets the time of its last answer.
    """

    @doc false
    defmacro __using__(opts) do
      resource = Keyword.fetch!(opts, :resource)
      priority = Keyword.get(opts, :priority, 50)

      quote do
        use MishkaInstaller.Event.Hook,
          event: unquote(MishkaPay.Events.webhook_answered()),
          initial: %{priority: unquote(priority)}

        @impl true
        def call(%{event: %MishkaPay.Event{}} = state),
          do: {:reply, MishkaPay.Ash.Inbox.Answer.record(unquote(resource), state)}

        def call(state), do: {:reply, state}
      end
    end

    require Ash.Query

    @doc false
    def record(resource, %{event: event, answer_ms: answer_ms, status: status} = state) do
      provider = event.provider
      event_id = event.id

      _result =
        resource
        |> Ash.Query.filter(provider == ^provider and event_id == ^event_id)
        |> Ash.bulk_update(:answered, %{answer_ms: answer_ms, answer_status: status},
          authorize?: false,
          notify?: true,
          strategy: [:atomic, :stream],
          return_errors?: true
        )

      state
    end
  end
end

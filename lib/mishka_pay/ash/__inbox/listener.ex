# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Inbox.Listener do
    @moduledoc """
    Makes a module the `mishka_pay:webhook:received` listener that stores each checked event in an
    inbox resource (`MishkaPay.Ash.Inbox`):

        defmodule MyApp.Pay.Inbox do
          use MishkaPay.Ash.Inbox.Listener, resource: MyApp.Pay.WebhookEvent
        end

    Supervise it like any plugin. It answers the webhook as soon as the event is stored, so the
    provider gets its 200 at once; an event it cannot store is answered as failed, so the provider
    sends it again. `:priority` places it among the other listeners (50 by default).
    """

    @doc false
    defmacro __using__(opts) do
      resource = Keyword.fetch!(opts, :resource)
      priority = Keyword.get(opts, :priority, 50)

      quote do
        use MishkaInstaller.Event.Hook,
          event: unquote(MishkaPay.Events.webhook_received()),
          initial: %{priority: unquote(priority)}

        @impl true
        def call(%{event: %MishkaPay.Event{} = event, failed: nil} = state),
          do: {:reply, MishkaPay.Ash.Inbox.Listener.store(unquote(resource), event, state)}

        def call(state), do: {:reply, state}
      end
    end

    @doc false
    def store(resource, event, state) do
      attrs = %{
        provider: event.provider,
        tenant: event.tenant && to_string(event.tenant),
        event_id: event.id,
        type: event.type,
        object_id: event.object_id,
        object_type: event.object_type,
        payment_id: event.payment_id,
        subscription_id: event.subscription_id,
        dispute_id: event.dispute_id,
        livemode: event.livemode,
        account: event.account,
        provider_created_at: event.created_at
      }

      case Ash.create(resource, attrs, action: :receive, authorize?: false) do
        {:ok, _stored} -> state
        {:error, error} -> %{state | failed: MishkaPay.Ash.message(error)}
      end
    end
  end
end

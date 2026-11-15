# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Payment.Listener do
    @moduledoc """
    Makes a module the `mishka_pay:event:process` listener that syncs the payment an event concerns
    into a payment resource (`MishkaPay.Ash.Payment`):

        defmodule MyApp.Pay.PaymentSync do
          use MishkaPay.Ash.Payment.Listener, resource: MyApp.Pay.Payment
        end

    Supervise it like any plugin. An event about no payment is left alone; a payment the provider
    cannot give fails the event, so the inbox tries it again later.
    """

    @doc false
    defmacro __using__(opts) do
      resource = Keyword.fetch!(opts, :resource)
      priority = Keyword.get(opts, :priority, 50)

      quote do
        use MishkaInstaller.Event.Hook,
          event: unquote(MishkaPay.Events.event_process()),
          initial: %{priority: unquote(priority)}

        @impl true
        def call(%{event: %MishkaPay.Event{payment_id: id} = event, failed: nil} = state)
            when is_binary(id),
            do: {:reply, MishkaPay.Ash.Payment.Listener.sync(unquote(resource), event, state)}

        def call(state), do: {:reply, state}
      end
    end

    @doc false
    def sync(resource, event, state) do
      args = %{
        provider: event.provider,
        payment_id: event.payment_id,
        tenant: event.tenant && to_string(event.tenant)
      }

      case Ash.create(resource, args, action: :sync, authorize?: false) do
        {:ok, _payment} -> state
        {:error, error} -> %{state | failed: MishkaPay.Ash.message(error)}
      end
    end
  end
end

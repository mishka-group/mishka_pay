# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Payment.Listener do
    @moduledoc """
    Makes a module the `mishka_pay:event:process` listener that syncs the payment an event concerns
    into a payment resource (the `:payment` kind of `MishkaPay.Ash.Resource`):

        defmodule MyApp.Pay.PaymentSync do
          use MishkaPay.Ash.Payment.Listener, resource: MyApp.Pay.Payment
        end

    `MishkaPay.Ash.Resource` makes one for each resource that listens (`listen? true`), as
    `<Resource>.MishkaPayListener`; write one by hand with `listen? false`, such as to give it
    another `:priority`. Supervise it like any plugin. An event about no payment is left alone;
    a payment the provider cannot give fails the event, so the inbox tries it again later.
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
    def sync(resource, event, state),
      do: MishkaPay.Ash.sync_event(resource, :payment_id, event.payment_id, event, state)
  end
end

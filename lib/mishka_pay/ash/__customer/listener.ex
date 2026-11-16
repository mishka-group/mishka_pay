# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Customer.Listener do
    @moduledoc """
    Makes a module the `mishka_pay:event:process` listener that syncs the customer an event is
    about (`customer.created`, `customer.updated`, `customer.deleted` on Stripe) into a customer
    resource (`MishkaPay.Ash.Customer`):

        defmodule MyApp.Pay.CustomerSync do
          use MishkaPay.Ash.Customer.Listener, resource: MyApp.Pay.Customer
        end

    Supervise it like any plugin. An event about anything else is left alone; a customer the
    provider cannot give fails the event, so the inbox tries it again later.
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
        def call(
              %{
                event: %MishkaPay.Event{object_type: "customer", object_id: id} = event,
                failed: nil
              } =
                state
            )
            when is_binary(id),
            do: {:reply, MishkaPay.Ash.Customer.Listener.sync(unquote(resource), event, state)}

        def call(state), do: {:reply, state}
      end
    end

    @doc false
    def sync(resource, event, state) do
      args = %{
        provider: event.provider,
        customer_id: event.object_id,
        tenant: event.tenant && to_string(event.tenant)
      }

      case Ash.create(resource, args, action: :sync, authorize?: false) do
        {:ok, _customer} -> state
        {:error, error} -> %{state | failed: MishkaPay.Ash.message(error)}
      end
    end
  end
end

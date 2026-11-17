# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Customer.Listener do
    @moduledoc """
    Makes a module the `mishka_pay:event:process` listener that syncs the customer an event is
    about (`customer.created`, `customer.updated`, `customer.deleted` on Stripe, the
    `setup_intent.*` and `payment_method.*` events of the customer's saved cards, and
    `customer.tax_id.*` for one of its tax ids) into a customer resource (the `:customer` kind of
    `MishkaPay.Ash.Resource`):

        defmodule MyApp.Pay.CustomerSync do
          use MishkaPay.Ash.Customer.Listener, resource: MyApp.Pay.Customer
        end

    `MishkaPay.Ash.Resource` makes one for each resource that listens (`listen? true`), as
    `<Resource>.MishkaPayListener`; write one by hand with `listen? false`, such as to give it
    another `:priority`. Supervise it like any plugin. An event about anything else is left
    alone; a customer the provider cannot give fails the event, so the inbox tries it again
    later. At Stripe a customer made on Accounts v2 sends the same account events as a seller's
    account (`v2.core.account.updated`, `.closed`, `[identity].updated`), each naming the
    account as its customer: an account the read finds is no customer (`resource_missing`) is
    left alone, and its event is done.
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
                event: %MishkaPay.Event{customer_id: id} = event,
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
    def sync(resource, %MishkaPay.Event{customer_id: id} = event, state),
      do:
        MishkaPay.Ash.sync_event(
          resource,
          :customer_id,
          id,
          event,
          state,
          &not_a_customer?(id, &1)
        )

    # An account event names the account as its customer; one that is only a seller is none.
    defp not_a_customer?("acct_" <> _id, error),
      do:
        match?(
          %MishkaPay.Errors.Rejected{code: "resource_missing"},
          MishkaPay.Ash.provider_error(error)
        )

    defp not_a_customer?(_customer_id, _error), do: false
  end
end

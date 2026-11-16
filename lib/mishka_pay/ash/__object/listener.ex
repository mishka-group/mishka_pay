# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Object.Listener do
    @moduledoc """
    Makes a module the `mishka_pay:event:process` listener that syncs the provider object an event
    is about into a resource of a site-managed kind (`MishkaPay.Ash.Object.Spec`): a
    `product.updated` into the `:product` resource, an `invoice.paid` into the `:invoice` one.

        defmodule MyApp.Pay.ProductSync do
          use MishkaPay.Ash.Object.Listener, resource: MyApp.Pay.Product, kind: :product
        end

    `MishkaPay.Ash.Resource` makes one for each resource that listens (`listen? true`), as
    `<Resource>.MishkaPayListener`. An event about another object is left alone; an object the
    provider cannot give fails the event, so the inbox tries it again later.
    """

    @doc false
    defmacro __using__(opts) do
      resource = Keyword.fetch!(opts, :resource)
      kind = Keyword.fetch!(opts, :kind)
      priority = Keyword.get(opts, :priority, 50)
      object = MishkaPay.Ash.Object.Spec.object(kind)

      quote do
        use MishkaInstaller.Event.Hook,
          event: unquote(MishkaPay.Events.event_process()),
          initial: %{priority: unquote(priority)}

        @impl true
        def call(
              %{
                event: %MishkaPay.Event{object_type: unquote(object), object_id: id} = event,
                failed: nil
              } = state
            )
            when is_binary(id),
            do:
              {:reply,
               MishkaPay.Ash.sync_event(
                 unquote(resource),
                 unquote(MishkaPay.Ash.Object.Spec.id_argument(kind)),
                 id,
                 event,
                 state
               )}

        def call(state), do: {:reply, state}
      end
    end
  end
end

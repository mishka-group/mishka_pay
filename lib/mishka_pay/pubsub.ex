# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.PubSub do
  @moduledoc """
  Broadcasts Mishka Pay's changes on the host's own `Phoenix.PubSub`, so a LiveView, a channel or
  any process hears a payment, subscription, customer or dispute change at once. One line:

      defmodule MyApp.Pay.Broadcast do
        use MishkaPay.PubSub, pubsub: MyApp.PubSub
      end

      # application.ex children, after the PubSub
      MyApp.Pay.Broadcast

  It is a set of mishka_installer plugins, one on each `mishka_pay:*:changed` event
  (`MishkaPay.Events`); supervising the module starts them all. Every change goes to two topics:
  the kind's (`"mishka_pay:payments"`) and the kind's for its tenant
  (`"mishka_pay:site-42:payments"`), so a multi-site project subscribes each site's screens to its
  own changes only. `topic/3` builds them:

      Phoenix.PubSub.subscribe(MyApp.PubSub, MishkaPay.PubSub.topic(:payment, site.id))

      def handle_info({:mishka_pay, :payment, %{payment: payment, record: row}}, socket), do: ...

  The message is `{:mishka_pay, kind, changed}`: `kind` is `:payment`, `:subscription`,
  `:customer`, `:dispute`, `:invoice`, `:product`, `:price`, `:coupon`, `:promotion_code` or
  `:payment_link`, `changed` is what the event carried (the provider's struct under the
  kind's name, and the stored `:record`).

  Options:

    * `:pubsub` (required): the host's PubSub name.
    * `:kinds`: which changes to broadcast, every kind by default.
    * `:prefix`: the topics' first part, `"mishka_pay"` by default.
    * `:priority`: the plugins' priority on their events, 90 by default (after the host's own).
  """

  @kinds [
    :payment,
    :subscription,
    :customer,
    :dispute,
    :invoice,
    :product,
    :price,
    :coupon,
    :promotion_code,
    :payment_link
  ]

  @doc "The kinds of change it can broadcast."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  The topic of `kind` changes: for every tenant, or for `tenant` only. `prefix` is the plugin's
  `:prefix` option.

      iex> MishkaPay.PubSub.topic(:payment)
      "mishka_pay:payments"
      iex> MishkaPay.PubSub.topic(:dispute, "site-42")
      "mishka_pay:site-42:disputes"
  """
  @spec topic(atom(), term(), String.t()) :: String.t()
  def topic(kind, tenant \\ nil, prefix \\ "mishka_pay") when kind in @kinds do
    case tenant do
      nil -> "#{prefix}:#{kind}s"
      tenant -> "#{prefix}:#{tenant}:#{kind}s"
    end
  end

  @doc false
  def event(:payment), do: MishkaPay.Events.payment_changed()
  def event(:subscription), do: MishkaPay.Events.subscription_changed()
  def event(:customer), do: MishkaPay.Events.customer_changed()
  def event(:dispute), do: MishkaPay.Events.dispute_changed()
  def event(kind), do: MishkaPay.Events.changed(kind)

  @doc false
  # The tenant of a change: on its stored row, or on the provider's struct.
  def broadcast(pubsub, prefix, kind, state) do
    message = {:mishka_pay, kind, Map.take(state, [kind, :record])}
    tenant = tenant_of(state[:record]) || tenant_of(state[kind])

    Phoenix.PubSub.broadcast(pubsub, topic(kind, nil, prefix), message)

    case tenant do
      nil -> :ok
      tenant -> Phoenix.PubSub.broadcast(pubsub, topic(kind, tenant, prefix), message)
    end
  end

  defp tenant_of(%{tenant: tenant}) when not is_nil(tenant), do: tenant
  defp tenant_of(_none), do: nil

  @doc false
  defmacro __using__(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    kinds = Keyword.get(opts, :kinds, @kinds)
    prefix = Keyword.get(opts, :prefix, "mishka_pay")
    priority = Keyword.get(opts, :priority, 90)

    for kind <- kinds, kind not in @kinds do
      raise ArgumentError, "MishkaPay.PubSub kinds are #{inspect(@kinds)}, got: #{inspect(kind)}"
    end

    hooks =
      for kind <- kinds do
        name = kind |> Atom.to_string() |> Macro.camelize() |> String.to_atom()

        quote do
          defmodule unquote({:__aliases__, [alias: false], [name]}) do
            @moduledoc false
            use MishkaInstaller.Event.Hook,
              event: unquote(event(kind)),
              initial: %{priority: unquote(priority)}

            @impl true
            def call(state) do
              MishkaPay.PubSub.broadcast(unquote(pubsub), unquote(prefix), unquote(kind), state)
              {:reply, state}
            end
          end
        end
      end

    plugins =
      Enum.map(
        kinds,
        &Module.concat(__CALLER__.module, &1 |> Atom.to_string() |> Macro.camelize())
      )

    quote do
      unquote_splicing(hooks)

      @doc "The broadcasting plugins, one per kind of change."
      def plugins, do: unquote(plugins)

      @doc false
      def child_spec(_opts) do
        %{
          id: __MODULE__,
          type: :supervisor,
          start: {Supervisor, :start_link, [plugins(), [strategy: :one_for_one]]}
        }
      end
    end
  end
end

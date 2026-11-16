# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Test do
  @moduledoc """
  Helpers for a project's tests, the way `Igniter.Test` helps test a task: start a provider, give
  keys, answer HTTP calls, without a real provider and without sleeping.

  For a provider's own contract tests, see `MishkaPay.ProviderCase`.

  ## Setup

  In `test/test_helper.exs`, once mishka_installer runs (it does in a project that uses it):

      MishkaPay.Test.setup!()
      ExUnit.start()

  And in `config/test.exs`, so `stub_http/1` answers every provider call:

      config :mishka_pay, req_options: [plug: {Req.Test, MishkaPay.Client}]

  ## Webhooks without a provider

  `signed_event/4` makes a Stripe event, signed the way Stripe signs it, and `deliver_event/5`
  posts it through `MishkaPay.Webhook` as a test request; `stripe_object/2` gives one object of
  each kind Mishka Pay acts on, so a host tests its own listeners end to end:

      conn =
        MishkaPay.Test.deliver_event("site-a", "charge.dispute.created",
          MishkaPay.Test.stripe_object(:dispute, %{"payment_intent" => "pi_1"}),
          "whsec_test")

      assert conn.status == 200

  ## In a test

      test "a checkout with Acme" do
        MishkaPay.Test.start_plugin!(MyApp.Pay.Acme)
        MishkaPay.Test.put_keys("acme", %{secret_key: "sk_test_1"})
        MishkaPay.Test.stub_http(fn conn -> Req.Test.json(conn, %{"id" => "ch_1"}) end)
        # ... call your code
      end

  `put_keys/3` and `stub_http/1` belong to the test process and the processes it starts (through
  `$callers`), so tests that use only them can be `async: true`. `start_plugin!/1` changes an event
  every test sees, so a test that uses it is `async: false`.

  Every wait here is on a message: a plugin is ready when its event's compiled module runs it, which
  mishka_installer announces each time it rebuilds the event. Nothing sleeps; a plugin that never
  starts fails the test after 30 seconds.
  """

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias MishkaInstaller.Event.{Event, EventHandler, ModuleStateCompiler}
  alias MishkaInstaller.{MnesiaRepo, QueueAssistant}
  alias MishkaPay.Test.Keys

  @doc """
  Prepares a test run: mishka_installer's plugin registry (`start_registry!/0`) and the table
  `put_keys/3` writes to. Call it in `test_helper.exs`.
  """
  @spec setup!() :: :ok
  def setup! do
    start_registry!()
    Keys.new_table()
    :ok
  end

  @doc """
  Starts `MishkaPay.Registry` (mishka_installer's plugin registry) when its parts are not running
  and returns once it is synchronized: for a test run with no application that lists it, such as a
  library's own. A project whose application lists `MishkaPay.Registry` starts nothing here;
  `setup!/0` calls it first.
  """
  @spec start_registry!() :: :ok
  def start_registry! do
    case MishkaPay.Registry.missing() do
      [] ->
        :ok

      missing ->
        MishkaInstaller.subscribe("mnesia")

        try do
          {:ok, _supervisor} = Supervisor.start_link([MishkaPay.Registry], strategy: :one_for_one)
          if MnesiaRepo in missing, do: synchronized()
        after
          MishkaInstaller.unsubscribe("mnesia")
        end

        :ok
    end
  end

  defp synchronized do
    receive do
      %{channel: "mnesia", status: :synchronized} -> :ok
    after
      :timer.seconds(30) -> raise "the mishka_installer registry never synchronized"
    end
  end

  @doc """
  Returns once `plugin`, which the application already starts (its provider, its keys plugin),
  runs: its event registers it a moment after boot, so the first test could otherwise come first.
  Call it in `test_helper.exs`, after `setup!/0`.
  """
  @spec await_plugin!(module()) :: :ok
  def await_plugin!(plugin), do: await(plugin)

  @doc """
  Starts `plugin` (a project's provider or keys plugin) under the test supervisor and returns once
  its event runs it. It is unregistered when the test ends, even when it never started.
  """
  @spec start_plugin!(module()) :: :ok
  def start_plugin!(plugin) do
    MishkaInstaller.subscribe("event")

    try do
      start_supervised!(plugin)
      on_exit(fn -> Event.unregister(:name, plugin, false) end)
      wait(plugin)
    after
      MishkaInstaller.unsubscribe("event")
    end

    drain()
  end

  @doc """
  For this test, `MishkaPay.Credentials.fetch/2` answers `keys` for `provider`, for `tenant` or for
  every tenant when it is `:any`. It answers before the project's own keys plugins.
  """
  @spec put_keys(String.t(), map(), term()) :: :ok
  def put_keys(provider, keys, tenant \\ :any) when is_binary(provider) and is_map(keys) do
    test = self()
    Keys.put(test, provider, tenant, keys)
    on_exit(fn -> Keys.delete(test) end)
  end

  @doc """
  Answers every `MishkaPay.Client` request of this test with `plug`, a function of a `Plug.Conn`
  such as `&Req.Test.json(&1, %{"id" => "ch_1"})`. Needs the `:req_options` config above.
  """
  @spec stub_http((Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def stub_http(plug) when is_function(plug, 1) do
    Req.Test.stub(MishkaPay.Client, plug)
    :ok
  end

  @doc """
  Unregisters every plugin whose module name starts with one of `prefixes`
  (`"Elixir.MyApp.Test."`): test plugins a killed run left in mishka_installer's registry, which
  lives on disk. Call it in `test_helper.exs` before the run.
  """
  @spec sweep!([String.t()]) :: :ok
  def sweep!(prefixes) do
    for event <- List.wrap(Event.get()),
        String.starts_with?(to_string(event.name), prefixes) do
      Event.unregister(:name, event.name, false)
    end

    :ok
  end

  defp await(plugin) do
    MishkaInstaller.subscribe("event")

    try do
      wait(plugin)
    after
      MishkaInstaller.unsubscribe("event")
    end

    drain()
  end

  # The plugin runs once its event's compiled module lists it. Its `:started` row is not enough:
  # `Event.start/3` writes it before it queues the rebuild, so a reader can see the row while the
  # module is still the old one. The installer broadcasts `:purge_create` after each rebuild of an
  # event, and the caller subscribed before the plugin started, so no rebuild is missed.
  defp wait(plugin) do
    event = plugin.config(:__event__)

    if runs?(event, plugin) do
      :ok
    else
      receive do
        %{channel: "event", status: :purge_create, data: ^event} -> wait(plugin)
      after
        :timer.seconds(30) -> raise "#{inspect(plugin)} never started"
      end
    end
  end

  defp runs?(event, plugin) do
    case ModuleStateCompiler.event_module(event) do
      nil -> false
      module -> Enum.any?(module.initialize().plugins, &(&1.name == plugin))
    end
  end

  # Starting a plugin also queues the rebuild of every event whose plugins depend on it; once nothing
  # is queued or running those are rebuilt too. Each round is a sync call to the installer's event
  # handler, which answers between rebuilds: the barrier mishka_cms_core's tests use too.
  defp drain do
    state = EventHandler.get()

    case Keyword.get(state, :running, []) == [] and
           QueueAssistant.empty?(Keyword.get(state, :queues)) do
      true -> :ok
      false -> drain()
    end
  end

  @objects %{
    payment_intent: %{
      "object" => "payment_intent",
      "id" => "pi_test",
      "amount" => 1999,
      "currency" => "usd",
      "status" => "succeeded"
    },
    checkout_session: %{
      "object" => "checkout.session",
      "id" => "cs_test",
      "payment_intent" => "pi_test",
      "status" => "complete"
    },
    charge: %{"object" => "charge", "id" => "ch_test", "payment_intent" => "pi_test"},
    refund: %{"object" => "refund", "id" => "re_test", "payment_intent" => "pi_test"},
    dispute: %{
      "object" => "dispute",
      "id" => "du_test",
      "payment_intent" => "pi_test",
      "status" => "needs_response"
    },
    invoice: %{
      "object" => "invoice",
      "id" => "in_test",
      "parent" => %{"subscription_details" => %{"subscription" => "sub_test"}}
    },
    subscription: %{"object" => "subscription", "id" => "sub_test", "status" => "active"},
    customer: %{"object" => "customer", "id" => "cus_test", "email" => "buyer@example.com"},
    tax_id: %{
      "object" => "tax_id",
      "id" => "txi_test",
      "customer" => "cus_test",
      "type" => "eu_vat",
      "value" => "DE123456789"
    }
  }

  @doc """
  One Stripe object of `kind` (`:payment_intent`, `:checkout_session`, `:charge`, `:refund`,
  `:dispute`, `:invoice`, `:subscription`, `:customer` or `:tax_id`), with the ids Mishka Pay reads from it,
  and `overrides` merged on top.
  """
  @spec stripe_object(atom(), map()) :: map()
  def stripe_object(kind, overrides \\ %{}) do
    @objects |> Map.fetch!(kind) |> Map.merge(overrides)
  end

  @doc """
  A Stripe event of `type` about `object`, signed with webhook `secret` the way Stripe signs it:
  `{body, headers}`, ready to post. `opts`: `id:` (`"evt_test_..."` by default), `livemode:`
  (`false`), `at:` the signing time (now).
  """
  @spec signed_event(String.t(), map(), String.t(), keyword()) ::
          {binary(), [{String.t(), String.t()}]}
  def signed_event(type, object, secret, opts \\ [])
      when is_binary(type) and is_map(object) and is_binary(secret) do
    at = Keyword.get_lazy(opts, :at, fn -> System.system_time(:second) end)

    body =
      JSON.encode!(%{
        "id" =>
          Keyword.get_lazy(opts, :id, fn -> "evt_test_#{System.unique_integer([:positive])}" end),
        "object" => "event",
        "type" => type,
        "created" => at,
        "livemode" => Keyword.get(opts, :livemode, false),
        "data" => %{"object" => object}
      })

    signature = MishkaPay.Providers.Stripe.signature(body, at, secret)

    {body,
     [{"content-type", "application/json"}, {"stripe-signature", "t=#{at},v1=#{signature}"}]}
  end

  @doc """
  Posts a signed Stripe event for `tenant` through `MishkaPay.Webhook` and answers the test
  connection. `opts` also takes `at:` the webhook path (`"/pay/webhooks"`).
  """
  @spec deliver_event(term(), String.t(), map(), String.t(), keyword()) :: Plug.Conn.t()
  def deliver_event(tenant, type, object, secret, opts \\ []) do
    {body, headers} = signed_event(type, object, secret, opts)
    at = Keyword.get(opts, :at, "/pay/webhooks")

    headers
    |> Enum.reduce(Plug.Test.conn(:post, "#{at}/stripe/#{tenant}", body), fn {name, value},
                                                                             conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
    |> MishkaPay.Webhook.call(MishkaPay.Webhook.init(at: at))
  end
end

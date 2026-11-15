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

  Every wait here is on a message: a plugin is ready when mishka_installer says it started and its
  event is rebuilt. Nothing sleeps.
  """

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias MishkaInstaller.Event.{Event, EventHandler}
  alias MishkaInstaller.QueueAssistant
  alias MishkaPay.Test.Keys

  @doc """
  Prepares a test run: the table `put_keys/3` writes to and the keys plugin that reads it, started
  once and waited for. Call it in `test_helper.exs`.
  """
  @spec setup!() :: :ok
  def setup! do
    Keys.new_table()
    {:ok, _supervisor} = Supervisor.start_link([Keys], strategy: :one_for_one)
    await(Keys)
  end

  @doc """
  Starts `plugin` (a provider or a keys plugin) under the test supervisor and returns once its
  event runs it. It is unregistered when the test ends.
  """
  @spec start_plugin!(module()) :: :ok
  def start_plugin!(plugin) do
    MishkaInstaller.subscribe("event")

    try do
      start_supervised!(plugin)
      wait(plugin)
    after
      MishkaInstaller.unsubscribe("event")
    end

    drain()
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
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

  defp wait(plugin) do
    case Event.get(:name, plugin) do
      %{status: :started} ->
        :ok

      _not_yet ->
        receive do
          %{channel: "event", status: :start, data: %{name: ^plugin}} -> :ok
        after
          :timer.seconds(30) -> raise "#{inspect(plugin)} never started"
        end
    end
  end

  # `Event.start/3` queues the event's rebuild before it broadcasts, so once nothing is queued or
  # running the rebuilt event includes the plugin.
  defp drain do
    state = EventHandler.get()

    case Keyword.get(state, :running, []) == [] and
           QueueAssistant.empty?(Keyword.get(state, :queues)) do
      true -> :ok
      false -> drain()
    end
  end
end

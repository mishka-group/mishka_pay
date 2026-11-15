# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Test.Installer do
  @moduledoc """
  mishka_installer plugins in a test run, the same helper as `MishkaCmsCore.Test.Installer`.

  `start!/1` starts a plugin for the length of a test and returns once it is registered and its
  event is rebuilt, so the next line already sees it. `sweep!/1` unregisters the test plugins an
  earlier run left in the registry, which lives on disk.

  The compiled event is global, so a test that starts a plugin is `async: false`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias MishkaInstaller.Event.{Event, EventHandler}
  alias MishkaInstaller.QueueAssistant

  @doc "Starts `plugin` under the test supervisor and waits until its event runs it."
  @spec start!(module()) :: :ok
  def start!(plugin) do
    MishkaInstaller.subscribe("event")
    start_supervised!(plugin)
    wait(plugin)
    MishkaInstaller.unsubscribe("event")
    drain()

    on_exit(fn -> Event.unregister(:name, plugin, false) end)
    :ok
  end

  @doc """
  Unregisters every plugin whose module name (`"Elixir.MishkaPay.Test.Acme"`) starts with one of
  `prefixes`.
  """
  @spec sweep!([String.t()]) :: :ok
  def sweep!(prefixes) do
    for event <- List.wrap(Event.get()),
        String.starts_with?(to_string(event.name), prefixes) do
      Event.unregister(:name, event.name, false)
    end

    :ok
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

  # `Event.start/3` queues the event's rebuild before it broadcasts, so once the queue and the
  # running list are empty the rebuilt event includes the plugin.
  defp drain do
    state = EventHandler.get()

    case Keyword.get(state, :running, []) == [] and
           QueueAssistant.empty?(Keyword.get(state, :queues)) do
      true -> :ok
      false -> drain()
    end
  end
end

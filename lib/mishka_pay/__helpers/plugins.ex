# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Helpers.Plugins do
  @moduledoc """
  Runs the host plugins of a mishka_installer event so that none of them can take the caller down:
  in a task under `MishkaPay.TaskSupervisor`, not linked to the caller, within a time limit. Used for
  the keys plugins (`MishkaPay.Credentials`) and the checkout gate (`MishkaPay.checkout/1`).
  """

  require Logger

  alias MishkaInstaller.Event.Hook

  @type failure :: :cannot_run | :raised | :exited | :timeout

  @doc """
  The event's answer to `state`, or why there is none: `:cannot_run` (a plugin is registered but
  not loaded), `:raised`, `:exited` (an `exit` or `throw`, logged with its exit) or `:timeout`.
  """
  @spec call(String.t(), term(), timeout()) :: {:ok, term()} | {:error, failure()}
  def call(event, state, timeout) do
    task =
      Task.Supervisor.async_nolink(MishkaPay.TaskSupervisor, fn ->
        Hook.call(event, state, cannot_run: {:error, :cannot_run}, raised: {:error, :raised})
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:error, reason}} when reason in [:cannot_run, :raised] -> {:error, reason}
      {:ok, answer} -> {:ok, answer}
      {:exit, reason} -> exited(event, reason)
      nil -> {:error, :timeout}
    end
  end

  defp exited(event, reason) do
    Logger.warning("mishka_pay: a plugin of #{event} exited: " <> Exception.format_exit(reason))
    {:error, :exited}
  end
end

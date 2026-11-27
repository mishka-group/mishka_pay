# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Helpers.Plugins do
  @moduledoc """
  Runs the host plugins of a mishka_installer event so that none of them can take the caller down:
  in a task under `MishkaPay.TaskSupervisor`, not linked to the caller, within a time limit. Used for
  the keys plugins (`MishkaPay.Credentials`) and the checkout gate (`MishkaPay.checkout/1`).

  A task that exits or throws is reported by the kind of its exit only. The task carries the
  `:mishka_pay_plugin` logger metadata, and the primary filter `log_filter/2`, which
  `MishkaPay.Application` adds at start, drops the crash reports OTP logs for such a task (domain
  `[:otp | _]`), since they print the exit with every term it holds: the state, and with it an
  email or a key. Every other log, the plugin's own included, passes untouched.
  """

  require Logger

  alias MishkaInstaller.Event.Hook

  @type failure :: :cannot_run | :raised | :exited | :timeout

  @filter_id :mishka_pay_plugin_crash_reports

  @doc """
  The event's answer to `state`, or why there is none: `:cannot_run` (a plugin is registered but
  not loaded), `:raised`, `:exited` (an `exit` or `throw`, logged with the class of its exit
  only, never the exit itself, which may carry the state and with it an email or a key) or
  `:timeout`.
  """
  @spec call(String.t(), term(), timeout()) :: {:ok, term()} | {:error, failure()}
  def call(event, state, timeout) do
    task =
      Task.Supervisor.async_nolink(MishkaPay.TaskSupervisor, fn ->
        :logger.update_process_metadata(%{mishka_pay_plugin: event})
        Hook.call(event, state, cannot_run: {:error, :cannot_run}, raised: {:error, :raised})
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:error, reason}} when reason in [:cannot_run, :raised] -> {:error, reason}
      {:ok, answer} -> {:ok, answer}
      {:exit, reason} -> exited(event, reason)
      nil -> {:error, :timeout}
    end
  end

  @doc """
  Adds `log_filter/2` as a `:logger` primary filter; `MishkaPay.Application` calls it at start.
  Adding it again is a no-op.
  """
  @spec add_log_filter() :: :ok
  def add_log_filter do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.log_filter/2, nil}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
    end
  end

  @doc """
  Takes `log_filter/2` off `:logger`; `MishkaPay.Application` calls it when it stops.
  """
  @spec remove_log_filter() :: :ok
  def remove_log_filter do
    _removed = :logger.remove_primary_filter(@filter_id)
    :ok
  end

  @doc """
  The `:logger` primary filter: `:stop` for an OTP report (a task's or `proc_lib`'s crash report)
  logged by a plugin task, `:ignore` for every other event. It reads two keys of the event's
  metadata and nothing else, so the rest of the host's logging pays a map match.
  """
  @spec log_filter(:logger.log_event(), term()) :: :stop | :ignore
  def log_filter(%{meta: %{mishka_pay_plugin: _event, domain: [:otp | _domain]}}, _extra),
    do: :stop

  def log_filter(_log_event, _extra), do: :ignore

  defp exited(event, reason) do
    Logger.warning("mishka_pay: a plugin of #{event} exited: " <> exit_class(reason))
    {:error, :exited}
  end

  # What kind of exit it was, without its terms: the exception's module, the atom, or the tag of
  # a tuple.
  defp exit_class({%{__exception__: true} = exception, _stack}), do: inspect(exception.__struct__)
  defp exit_class({{:nocatch, _value}, _stack}), do: "a throw"
  defp exit_class({tag, _detail}) when is_atom(tag), do: inspect(tag)
  defp exit_class(reason) when is_atom(reason), do: inspect(reason)
  defp exit_class(_other), do: "an exit"
end

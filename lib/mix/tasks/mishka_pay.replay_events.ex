# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.MishkaPay.ReplayEvents do
  @shortdoc "Delivers again the provider events a site missed while its webhook was down"

  @moduledoc """
  Reads a tenant's events from its provider since a time and hands each to the project's
  `mishka_pay:webhook:received` listeners, oldest first (`MishkaPay.replay_events/3`): the Ash
  inbox stores the ones it does not have and works them as if the webhook had come. Run it after
  an outage. The project starts, for its keys and listeners.

      mix mishka_pay.replay_events --provider stripe --tenant site-42 --since 2026-11-15T08:00:00Z
      mix mishka_pay.replay_events --since 2026-11-15T08:00:00Z --type invoice.paid

  Options:

    * `--provider`: `stripe` by default.
    * `--tenant`: whose keys and events (none by default, for a single-site project).
    * `--since`: an ISO 8601 time; required. Stripe keeps 30 days of events.
    * `--type`: only this event type; more than once for several. By default every event Mishka
      Pay acts on.
  """

  use Mix.Task

  @switches [provider: :string, tenant: :string, since: :string, type: :keep]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    since = since!(opts[:since])
    Mix.Task.run("app.start")

    types =
      case Keyword.get_values(opts, :type) do
        [] -> []
        types -> [types: types]
      end

    case MishkaPay.replay_events(
           Keyword.get(opts, :provider, "stripe"),
           opts[:tenant],
           [since: since] ++ types
         ) do
      {:ok, %{delivered: delivered, failed: []}} ->
        Mix.shell().info("delivered #{delivered} events")

      {:ok, %{delivered: delivered, failed: failed}} ->
        Enum.each(failed, fn {id, reason} -> Mix.shell().error("#{id}: #{inspect(reason)}") end)
        Mix.raise("delivered #{delivered} events, #{length(failed)} failed")

      {:error, error} ->
        Mix.raise(Exception.message(error))
    end
  end

  defp since!(nil),
    do: Mix.raise("--since is required, an ISO 8601 time such as 2026-11-15T08:00:00Z")

  defp since!(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> Mix.raise("--since #{text} is not an ISO 8601 time")
    end
  end
end

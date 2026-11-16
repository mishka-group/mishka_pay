# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.MishkaPay.Stripe.CleanClocks do
  @shortdoc "Deletes old Stripe test clocks, with their customers and subscriptions"

  @moduledoc """
  Deletes a tenant's Stripe test clocks older than a number of hours; Stripe deletes each clock's
  customers and subscriptions with it. Test keys only (`MishkaPay.Providers.Stripe.TestClock`
  refuses live ones). The keys come from the project's own keys plugin, so the project starts.

      mix mishka_pay.stripe.clean_clocks --tenant site-42 --older-than 2
      mix mishka_pay.stripe.clean_clocks --name "live renewal" --dry-run

  Options:

    * `--tenant`: whose keys (none by default, for a single-site project).
    * `--older-than`: hours since the clock was made, 1 by default; `0` takes every clock.
    * `--name`: only clocks whose name starts with this.
    * `--dry-run`: lists what it would delete and deletes nothing.
  """

  use Mix.Task

  alias MishkaPay.Providers.Stripe.TestClock

  @switches [tenant: :string, older_than: :integer, name: :string, dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    tenant = opts[:tenant]
    since = DateTime.add(DateTime.utc_now(), -Keyword.get(opts, :older_than, 1), :hour)

    case TestClock.list(tenant) do
      {:ok, clocks} ->
        clocks
        |> Enum.filter(&old?(&1, since))
        |> Enum.filter(&named?(&1, opts[:name]))
        |> Enum.each(&clean(&1, tenant, opts[:dry_run]))

      {:error, error} ->
        Mix.raise(Exception.message(error))
    end
  end

  defp old?(%{created_at: %DateTime{} = at}, since), do: DateTime.compare(at, since) != :gt
  defp old?(_clock, _since), do: true

  defp named?(_clock, nil), do: true
  defp named?(%{name: name}, prefix), do: is_binary(name) and String.starts_with?(name, prefix)

  defp clean(clock, _tenant, true), do: Mix.shell().info("would delete #{clock.id} #{clock.name}")

  defp clean(clock, tenant, _delete) do
    case TestClock.delete(tenant, clock.id) do
      :ok -> Mix.shell().info("deleted #{clock.id} #{clock.name}")
      {:error, error} -> Mix.shell().error("#{clock.id}: #{Exception.message(error)}")
    end
  end
end

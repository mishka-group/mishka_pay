# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Application do
  @moduledoc """
  Mishka Pay's own processes: the task supervisor `MishkaPay.Credentials.fetch/3` runs a host's
  keys plugins under, so a plugin that exits, throws or hangs never takes the caller with it, and
  the logger filter that keeps such a plugin's crash report out of the log
  (`MishkaPay.Helpers.Plugins.log_filter/2`); the owner of the providers' token cache
  (`MishkaPay.Helpers.TokenCache`); and the providers (`plugins/0`), each a mishka_installer plugin
  it starts itself, as every Mishka CMS package starts its own.

  Which providers start is an option, all of them by default (a provider without a site's keys
  answers nothing for that site):

      config :mishka_pay, providers: [MishkaPay.Providers.Stripe]

  A provider waits for mishka_installer's registry and registers once it is up: inside Mishka CMS
  it always is; elsewhere see `MishkaPay.Registry`.
  """

  use Application

  @providers [MishkaPay.Providers.Stripe, MishkaPay.Providers.PayPal]

  @doc """
  The providers chosen (`config :mishka_pay, providers: [...]`), which Mishka CMS reads to check
  each package starts its own plugins.
  """
  @spec plugins() :: [module()]
  def plugins, do: Application.get_env(:mishka_pay, :providers, @providers)

  @impl true
  def start(_type, _args) do
    :ok = MishkaPay.Helpers.Plugins.add_log_filter()

    children =
      [
        {Task.Supervisor, name: MishkaPay.TaskSupervisor},
        MishkaPay.Helpers.TokenCache
      ] ++ plugins()

    opts = [strategy: :one_for_one, name: MishkaPay.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def stop(_state), do: MishkaPay.Helpers.Plugins.remove_log_filter()
end

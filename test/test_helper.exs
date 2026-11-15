# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Providers and credentials are mishka_installer plugins, so the suite runs with the installer's own
# registry. The library leaves its tree out when it was compiled for a test run, so the parts it
# left out are started here, and the run starts once the registry says it is synchronized.
MishkaInstaller.subscribe("mnesia")

{:ok, _} =
  Supervisor.start_link(
    [
      MishkaInstaller.Installer.CompileHandler,
      MishkaInstaller.Event.EventHandler,
      MishkaInstaller.MnesiaRepo
    ] -- MishkaInstaller.Application.supervised_children(),
    strategy: :one_for_one
  )

receive do
  %{channel: "mnesia", status: :synchronized} -> :ok
after
  :timer.seconds(30) -> raise "the mishka_installer registry never synchronized"
end

MishkaInstaller.unsubscribe("mnesia")

# A run killed part-way leaves its test plugins registered on disk; take them out first.
MishkaPay.Test.Installer.sweep!(["Elixir.MishkaPay.Test."])

ExUnit.start()

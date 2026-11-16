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

# The Ash layer's database, as a host runs it: the repo, Oban's tables and Oban itself, with each
# test checking out its own sandboxed connection (MishkaPay.DataCase).
repo = MishkaPay.Support.Repo
{:ok, _} = Supervisor.start_link([repo], strategy: :one_for_one)

Ecto.Migrator.run(repo, [{20_000_101_000_000, MishkaPay.Support.ObanMigration}], :up,
  all: true,
  log: false
)

{:ok, _} =
  Supervisor.start_link([{Oban, Application.fetch_env!(:mishka_pay, Oban)}],
    strategy: :one_for_one
  )

Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)

# A run killed part-way leaves its test plugins registered on disk; take them out first. Then the
# test kit starts, as a project using Mishka Pay starts it.
MishkaPay.Test.sweep!(["Elixir.MishkaPay.Support."])
MishkaPay.Test.setup!()

# Stripe tests run against Stripe's own mock server when it is up (see
# MishkaPay.Support.StripeMock), and against a real Stripe test account only with its key.
stripe_mock? = MishkaPay.Support.StripeMock.available?()

if System.get_env("STRIPE_MOCK_REQUIRED") && not stripe_mock?,
  do:
    raise("stripe-mock is required (STRIPE_MOCK_REQUIRED) but does not answer on localhost:12111")

excluded =
  [
    stripe_mock: not stripe_mock?,
    stripe_live: is_nil(System.get_env("STRIPE_SECRET_KEY")),
    paypal_live: is_nil(System.get_env("PAYPAL_CLIENT_SECRET"))
  ]
  |> Enum.filter(fn {_tag, skip?} -> skip? end)
  |> Enum.map(fn {tag, _skip?} -> tag end)

ExUnit.start(exclude: excluded)

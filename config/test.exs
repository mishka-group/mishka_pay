# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

import Config

# The plugin registry of a test run, on disk under the project and out of git (`.gitignore`).
config :mishka_installer, MishkaInstaller.MnesiaRepo,
  mnesia_dir: Path.expand("../.mnesia/test", __DIR__),
  essential: [MishkaInstaller.Event.Event, MishkaInstaller.Installer.Installer]

# Keep the run quiet: the installer logs every registry step at debug and info.
config :logger, level: :warning

# Every provider call of a test is answered by `MishkaPay.Test.stub_http/1`.
config :mishka_pay, req_options: [plug: {Req.Test, MishkaPay.Client}]

# Each test starts the providers it uses (MishkaPay.Test.start_plugin!/1).
config :mishka_pay, providers: []

# The Ash layer's tests keep their resources in Postgres, as a host does; POSTGRES_PORT lets a
# local run use a database of its own.
config :mishka_pay, MishkaPay.Support.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: "mishka_pay_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :mishka_pay,
  ecto_repos: [MishkaPay.Support.Repo],
  ash_domains: [MishkaPay.Support.Domain]

# Jobs run only when a test runs them, so a test waits on nothing.
config :mishka_pay, Oban,
  repo: MishkaPay.Support.Repo,
  testing: :manual,
  queues: [mishka_pay_inbox: 5]

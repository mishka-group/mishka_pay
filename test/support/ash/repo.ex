# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Repo do
  @moduledoc "The test database a host would bring: Postgres through AshPostgres."

  use AshPostgres.Repo, otp_app: :mishka_pay

  @impl true
  def installed_extensions, do: ["ash-functions"]

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end

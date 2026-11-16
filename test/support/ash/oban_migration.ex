# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.ObanMigration do
  @moduledoc """
  Oban's own tables for the test database. Oban's schema is not an Ash resource, so
  `mix ash.codegen` never makes it; the test helper runs this one, as a host's migration would.
  """

  use Ecto.Migration

  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end

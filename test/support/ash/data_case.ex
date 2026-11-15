# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.DataCase do
  @moduledoc """
  A test that uses the Ash layer's database: each test gets its own sandboxed connection, shared
  with the processes it starts (a plugin's task, an Oban job run inline), so tests stay apart.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Oban.Testing, repo: MishkaPay.Support.Repo
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MishkaPay.Support.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end

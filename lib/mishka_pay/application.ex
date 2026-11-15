# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Application do
  @moduledoc """
  Mishka Pay's own processes: the task supervisor `MishkaPay.Credentials.fetch/3` runs a host's
  keys plugins under, so a plugin that exits, throws or hangs never takes the caller with it.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [{Task.Supervisor, name: MishkaPay.TaskSupervisor}]
    opts = [strategy: :one_for_one, name: MishkaPay.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

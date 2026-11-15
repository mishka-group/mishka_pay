# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.EventWorker do
  @moduledoc """
  A host's `mishka_pay:event:process` listener: it tells the test that runs the job what it got,
  and cannot finish an event of type `"work.fails"`.
  """

  use MishkaInstaller.Event.Hook, event: "mishka_pay:event:process"

  @impl true
  def call(%{event: %{type: "work.fails"}} = state),
    do: {:reply, %{state | failed: "the store is down"}}

  def call(%{event: event} = state) do
    case Process.get(:"$callers") do
      [test | _] -> send(test, {:processing, event})
      _none -> :ok
    end

    {:reply, state}
  end
end

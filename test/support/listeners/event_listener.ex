# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.EventListener do
  @moduledoc """
  A host's `mishka_pay:webhook:received` listener. It tells the test that sent the webhook (its
  first `$callers`) what it got, and fails on an event of type `"listener.fails"`.
  """

  use MishkaInstaller.Event.Hook, event: "mishka_pay:webhook:received"

  @impl true
  def call(%{event: %{type: "listener.fails"}} = state),
    do: {:reply, %{state | failed: "the inbox is full"}}

  def call(%{event: event} = state) do
    case Process.get(:"$callers") do
      [test | _] -> send(test, {:webhook_event, event})
      _none -> :ok
    end

    {:reply, state}
  end
end

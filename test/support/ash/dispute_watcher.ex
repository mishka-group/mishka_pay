# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.DisputeWatcher do
  @moduledoc "A host's `mishka_pay:dispute:changed` listener: it tells the test what changed."

  use MishkaInstaller.Event.Hook, event: "mishka_pay:dispute:changed"

  @impl true
  def call(%{dispute: dispute, record: record} = state) do
    case Process.get(:"$callers") do
      [test | _] -> send(test, {:dispute_changed, dispute, record})
      _none -> :ok
    end

    {:reply, state}
  end
end

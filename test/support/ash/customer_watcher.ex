# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.CustomerWatcher do
  @moduledoc "A host's `mishka_pay:customer:changed` listener: it tells the test what changed."

  use MishkaInstaller.Event.Hook, event: "mishka_pay:customer:changed"

  @impl true
  def call(%{customer: customer, record: record} = state) do
    case Process.get(:"$callers") do
      [test | _] -> send(test, {:customer_changed, customer, record})
      _none -> :ok
    end

    {:reply, state}
  end
end

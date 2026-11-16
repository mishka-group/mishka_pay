# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.SubscriptionWatcher do
  @moduledoc "A host's `mishka_pay:subscription:changed` listener: it tells the test what changed."

  use MishkaInstaller.Event.Hook, event: "mishka_pay:subscription:changed"

  @impl true
  def call(%{subscription: subscription, record: record} = state) do
    case Process.get(:"$callers") do
      [test | _] -> send(test, {:subscription_changed, subscription, record})
      _none -> :ok
    end

    {:reply, state}
  end
end

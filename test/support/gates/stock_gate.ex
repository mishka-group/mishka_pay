# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.StockGate do
  @moduledoc """
  A host's `mishka_pay:checkout:before` plugin: it refuses an order marked out of stock and stamps
  every other checkout with the shop's channel.
  """

  use MishkaInstaller.Event.Hook, event: "mishka_pay:checkout:before"

  @impl true
  def call(%{checkout: %{reference: "out-of-stock"}} = state),
    do: {:reply, %{state | refused: "the ebook is out of stock"}}

  # A gate with bugs, one per reference.
  def call(%{checkout: %{reference: "gate-junk"}}), do: {:reply, :nonsense}

  def call(%{checkout: %{reference: "gate-no-checkout"}} = state),
    do: {:reply, %{state | checkout: nil}}

  def call(%{checkout: %{reference: "gate-exit"}}), do: exit(:gate_down)

  def call(%{checkout: checkout} = state),
    do: {:reply, %{state | checkout: %{checkout | metadata: %{"channel" => "web"}}}}
end

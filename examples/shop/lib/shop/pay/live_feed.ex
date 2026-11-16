defmodule Shop.Pay.LiveFeed do
  @moduledoc """
  Listens on `mishka_pay:payment:changed` and tells every open page, so a paid or refunded
  payment shows at once.
  """

  use MishkaInstaller.Event.Hook, event: "mishka_pay:payment:changed"

  @topic "payments"

  @doc "The PubSub topic the shop page listens on."
  def topic, do: @topic

  @impl true
  def call(%{record: record} = state) do
    Phoenix.PubSub.broadcast(Shop.PubSub, @topic, {:payment_changed, record})
    {:reply, state}
  end
end

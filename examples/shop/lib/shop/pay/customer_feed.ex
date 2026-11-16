defmodule Shop.Pay.CustomerFeed do
  @moduledoc """
  Listens on `mishka_pay:customer:changed` and tells every open page, so a customer registered,
  edited, or changed on Stripe's side (through its webhook) shows at once.
  """

  use MishkaInstaller.Event.Hook, event: "mishka_pay:customer:changed"

  @topic "pay:customers"

  @doc "The PubSub topic the shop page listens on."
  def topic, do: @topic

  @impl true
  def call(%{record: record} = state) do
    Phoenix.PubSub.broadcast(Shop.PubSub, @topic, {:customer_changed, record})
    {:reply, state}
  end
end

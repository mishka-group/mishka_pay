defmodule Shop.Pay.SubscriptionFeed do
  @moduledoc """
  Listens on `mishka_pay:subscription:changed` and tells every open page, so a subscription that
  renews, is cancelled or resumed shows at once.
  """

  use MishkaInstaller.Event.Hook, event: "mishka_pay:subscription:changed"

  @topic "pay:subscriptions"

  @doc "The PubSub topic the shop page listens on."
  def topic, do: @topic

  @impl true
  def call(%{record: record} = state) do
    Phoenix.PubSub.broadcast(Shop.PubSub, @topic, {:subscription_changed, record})
    {:reply, state}
  end
end

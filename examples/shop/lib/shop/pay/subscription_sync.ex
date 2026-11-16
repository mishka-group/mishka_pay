defmodule Shop.Pay.SubscriptionSync do
  @moduledoc "Syncs `Shop.Pay.Subscription` from Stripe for each stored event about a subscription."
  use MishkaPay.Ash.Subscription.Listener, resource: Shop.Pay.Subscription
end

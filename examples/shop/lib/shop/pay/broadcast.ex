defmodule Shop.Pay.Broadcast do
  @moduledoc """
  Mishka Pay's PubSub plugin: every payment, subscription, customer and dispute change goes to
  `Shop.PubSub`, on the kind's topic and the site's, so each open page hears its own site's
  changes at once.
  """
  use MishkaPay.PubSub, pubsub: Shop.PubSub
end

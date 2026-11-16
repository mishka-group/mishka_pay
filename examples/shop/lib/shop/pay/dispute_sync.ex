defmodule Shop.Pay.DisputeSync do
  @moduledoc "Syncs `Shop.Pay.Dispute` from Stripe for each stored `charge.dispute.*` event."
  use MishkaPay.Ash.Dispute.Listener, resource: Shop.Pay.Dispute
end

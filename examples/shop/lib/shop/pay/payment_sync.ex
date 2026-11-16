defmodule Shop.Pay.PaymentSync do
  @moduledoc "Syncs `Shop.Pay.Payment` from Stripe for each stored event about a payment."
  use MishkaPay.Ash.Payment.Listener, resource: Shop.Pay.Payment
end

defmodule Shop.Pay.CustomerSync do
  @moduledoc "Syncs `Shop.Pay.Customer` from Stripe for each stored event about a customer."
  use MishkaPay.Ash.Customer.Listener, resource: Shop.Pay.Customer
end

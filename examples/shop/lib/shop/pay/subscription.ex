defmodule Shop.Pay.Subscription do
  @moduledoc "One row per subscription, kept in sync with Stripe by Mishka Pay's `:subscription` kind."

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :subscription
  end

  postgres do
    table "subscriptions"
    repo Shop.Repo
  end
end

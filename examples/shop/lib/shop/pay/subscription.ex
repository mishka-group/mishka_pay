defmodule Shop.Pay.Subscription do
  @moduledoc "One row per subscription, kept in sync with Stripe by `MishkaPay.Ash.Subscription`."

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    fragments: [MishkaPay.Ash.Subscription]

  postgres do
    table "subscriptions"
    repo Shop.Repo
  end
end

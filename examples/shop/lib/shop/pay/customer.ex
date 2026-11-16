defmodule Shop.Pay.Customer do
  @moduledoc "One row per Stripe customer, kept in sync by `MishkaPay.Ash.Customer`."

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    fragments: [MishkaPay.Ash.Customer]

  postgres do
    table "customers"
    repo Shop.Repo
  end
end

defmodule Shop.Pay.Customer do
  @moduledoc "One row per Stripe customer, kept in sync by Mishka Pay's `:customer` kind."

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :customer
  end

  postgres do
    table "customers"
    repo Shop.Repo
  end
end

defmodule Shop.Pay.CatalogPrice do
  @moduledoc "One row per Stripe price the site manages from its admin, kept by Mishka Pay's `:price` kind."

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :price
  end

  postgres do
    table "pay_prices"
    repo Shop.Repo
  end
end

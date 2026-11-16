defmodule Shop.Pay.CatalogProduct do
  @moduledoc """
  One row per Stripe product the site manages from its admin, kept by Mishka Pay's `:product`
  kind. `Shop.Catalog.Product` is the shop's own product list; this is Stripe's side of it.
  """

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :product
  end

  postgres do
    table "pay_products"
    repo Shop.Repo
  end
end

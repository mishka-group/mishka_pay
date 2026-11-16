defmodule Shop.Catalog.Product do
  @moduledoc """
  A product the demo shop sells, paid once or, with an `:interval`, a plan sold as a subscription.
  The seeds (`priv/repo/seeds.exs`) fill them. Once published to Stripe's catalog
  (`Shop.Pay.CatalogPublisher`) it keeps its Stripe product and price ids, and a checkout sells
  that price by its id.
  """

  use Ash.Resource, domain: Shop.Pay, data_layer: AshPostgres.DataLayer

  postgres do
    table "products"
    repo Shop.Repo
  end

  actions do
    defaults [:read]

    create :seed do
      accept [
        :slug,
        :name,
        :price,
        :icon,
        :tax_code,
        :position,
        :active,
        :interval,
        :interval_count,
        :trial_days
      ]

      upsert? true
      upsert_identity :slug

      upsert_fields [
        :name,
        :price,
        :icon,
        :tax_code,
        :position,
        :active,
        :interval,
        :interval_count,
        :trial_days
      ]
    end

    update :published do
      accept [:stripe_product_id, :stripe_price_id]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :price, :decimal, allow_nil?: false, public?: true
    attribute :icon, :string, allow_nil?: false, default: "hero-shopping-bag", public?: true

    # Stripe Managed Payments needs a tax code on every price; txcd_10302000 is a digital book.
    attribute :tax_code, :string, allow_nil?: false, default: "txcd_10302000", public?: true
    attribute :position, :integer, allow_nil?: false, default: 0, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true

    # A plan: charged again every `interval_count` `interval`s, as a subscription, after an
    # optional trial. Left out, the product is paid once.
    attribute :interval, :atom, constraints: [one_of: [:day, :week, :month, :year]], public?: true
    attribute :interval_count, :integer, allow_nil?: false, default: 1, public?: true
    attribute :trial_days, :integer, public?: true

    # Set by publishing to Stripe's catalog: the product there and the price a checkout sells.
    attribute :stripe_product_id, :string, public?: true
    attribute :stripe_price_id, :string, public?: true
    timestamps()
  end

  identities do
    identity :slug, [:slug]
  end
end

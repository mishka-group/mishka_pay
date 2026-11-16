defmodule Shop.Catalog.Product do
  @moduledoc "A product the demo shop sells. The seeds (`priv/repo/seeds.exs`) fill them."

  use Ash.Resource, domain: Shop.Pay, data_layer: AshPostgres.DataLayer

  postgres do
    table "products"
    repo Shop.Repo
  end

  actions do
    defaults [:read]

    create :seed do
      accept [:slug, :name, :price, :icon, :tax_code, :position, :active]
      upsert? true
      upsert_identity :slug
      upsert_fields [:name, :price, :icon, :tax_code, :position, :active]
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
    timestamps()
  end

  identities do
    identity :slug, [:slug]
  end
end

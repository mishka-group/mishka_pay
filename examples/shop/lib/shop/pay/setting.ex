defmodule Shop.Pay.Setting do
  @moduledoc """
  A site's payment settings, kept in the database and changed from the page. `Shop.Pay.Keys` and
  `Shop.Pay.Gate` read them on every Mishka Pay call, so a change applies to the next checkout or refund with
  no restart and no `config.exs`: each site (tenant) of a multi-site project has its own row.
  """

  use Ash.Resource, domain: Shop.Pay, data_layer: AshPostgres.DataLayer

  postgres do
    table "pay_settings"
    repo Shop.Repo
  end

  actions do
    defaults [:read]

    create :save do
      accept [:tenant, :refunds, :merchant_of_record, :automatic_tax, :open]
      upsert? true
      upsert_identity :tenant
      upsert_fields [:refunds, :merchant_of_record, :automatic_tax, :open]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :tenant, :string, allow_nil?: false, public?: true

    attribute :refunds, :atom,
      constraints: [one_of: [:once, :many]],
      default: :once,
      allow_nil?: false,
      public?: true

    attribute :merchant_of_record, :boolean, public?: true

    # Stripe Tax for every checkout and payment link of the site, unless one says otherwise.
    attribute :automatic_tax, :boolean, allow_nil?: false, default: false, public?: true

    # Read by `Shop.Pay.Gate` before every checkout: a closed shop refuses to sell.
    attribute :open, :boolean, allow_nil?: false, default: true, public?: true
    timestamps()
  end

  identities do
    identity :tenant, [:tenant]
  end
end

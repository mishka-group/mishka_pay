# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# A multi-tenant host's site-managed provider objects, as a Mishka CMS extension keeps them for its
# admin pages: Ash multitenancy on the host's own `:site_id`, one resource per kind.

defmodule MishkaPay.Support.SiteProduct do
  @moduledoc "A site's products, the `:product` kind of `MishkaPay.Ash.Resource`."

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  postgres do
    table "site_products"
    repo MishkaPay.Support.Repo
  end

  mishka_pay do
    kind :product
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
  end

  attributes do
    attribute :site_id, :string, allow_nil?: false, public?: true
  end
end

defmodule MishkaPay.Support.SitePrice do
  @moduledoc "A site's prices, the `:price` kind of `MishkaPay.Ash.Resource`."

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  postgres do
    table "site_prices"
    repo MishkaPay.Support.Repo
  end

  mishka_pay do
    kind :price
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
  end

  attributes do
    attribute :site_id, :string, allow_nil?: false, public?: true
  end
end

defmodule MishkaPay.Support.SiteCoupon do
  @moduledoc "A site's coupons, the `:coupon` kind of `MishkaPay.Ash.Resource`."

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  postgres do
    table "site_coupons"
    repo MishkaPay.Support.Repo
  end

  mishka_pay do
    kind :coupon
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
  end

  attributes do
    attribute :site_id, :string, allow_nil?: false, public?: true
  end
end

defmodule MishkaPay.Support.SitePromotionCode do
  @moduledoc "A site's promotion codes, the `:promotion_code` kind of `MishkaPay.Ash.Resource`."

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  postgres do
    table "site_promotion_codes"
    repo MishkaPay.Support.Repo
  end

  mishka_pay do
    kind :promotion_code
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
  end

  attributes do
    attribute :site_id, :string, allow_nil?: false, public?: true
  end
end

defmodule MishkaPay.Support.SitePaymentLink do
  @moduledoc "A site's payment links, the `:payment_link` kind of `MishkaPay.Ash.Resource`."

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  postgres do
    table "site_payment_links"
    repo MishkaPay.Support.Repo
  end

  mishka_pay do
    kind :payment_link
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
  end

  attributes do
    attribute :site_id, :string, allow_nil?: false, public?: true
  end
end

defmodule MishkaPay.Support.SiteInvoice do
  @moduledoc "A site's invoices, the `:invoice` kind of `MishkaPay.Ash.Resource`."

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  postgres do
    table "site_invoices"
    repo MishkaPay.Support.Repo
  end

  mishka_pay do
    kind :invoice
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
  end

  attributes do
    attribute :site_id, :string, allow_nil?: false, public?: true
  end
end

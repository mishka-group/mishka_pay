defmodule Shop.Pay.Coupon do
  @moduledoc "One row per Stripe coupon the site manages from its admin, kept by Mishka Pay's `:coupon` kind."

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :coupon
  end

  postgres do
    table "pay_coupons"
    repo Shop.Repo
  end
end

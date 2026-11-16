defmodule Shop.Pay.PromotionCode do
  @moduledoc """
  One row per Stripe promotion code the site manages from its admin, kept by Mishka Pay's
  `:promotion_code` kind.
  """

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :promotion_code
  end

  postgres do
    table "pay_promotion_codes"
    repo Shop.Repo
  end
end

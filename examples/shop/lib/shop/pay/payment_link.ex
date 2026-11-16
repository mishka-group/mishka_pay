defmodule Shop.Pay.PaymentLink do
  @moduledoc """
  One row per Stripe payment link the site manages from its admin, kept by Mishka Pay's
  `:payment_link` kind.
  """

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :payment_link
  end

  postgres do
    table "pay_payment_links"
    repo Shop.Repo
  end
end

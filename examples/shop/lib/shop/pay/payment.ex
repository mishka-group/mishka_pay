defmodule Shop.Pay.Payment do
  @moduledoc "One row per payment, kept in sync with Stripe by Mishka Pay's `:payment` kind."

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :payment
  end

  postgres do
    table "payments"
    repo Shop.Repo
  end
end

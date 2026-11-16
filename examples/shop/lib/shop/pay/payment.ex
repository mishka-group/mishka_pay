defmodule Shop.Pay.Payment do
  @moduledoc "One row per payment, kept in sync with Stripe by `MishkaPay.Ash.Payment`."

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    fragments: [MishkaPay.Ash.Payment]

  postgres do
    table "payments"
    repo Shop.Repo
  end
end

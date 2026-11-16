defmodule Shop.Pay.Dispute do
  @moduledoc "One row per Stripe dispute (chargeback), kept in sync by Mishka Pay's `:dispute` kind."

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :dispute
  end

  postgres do
    table "disputes"
    repo Shop.Repo
  end
end

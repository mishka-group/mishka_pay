defmodule Shop.Pay.Dispute do
  @moduledoc "One row per Stripe dispute (chargeback), kept in sync by `MishkaPay.Ash.Dispute`."

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    fragments: [MishkaPay.Ash.Dispute]

  postgres do
    table "disputes"
    repo Shop.Repo
  end
end

defmodule Shop.Pay.WebhookEvent do
  @moduledoc "Each Stripe webhook, stored once and worked as a job by `MishkaPay.Ash.Inbox`."

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    fragments: [MishkaPay.Ash.Inbox]

  postgres do
    table("webhook_events")
    repo(Shop.Repo)
  end
end

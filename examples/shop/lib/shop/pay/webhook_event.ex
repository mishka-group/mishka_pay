defmodule Shop.Pay.WebhookEvent do
  @moduledoc "Each Stripe webhook, stored once and worked as a job by `MishkaPay.Ash.Inbox`."

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    fragments: [MishkaPay.Ash.Inbox],
    notifiers: [Ash.Notifier.PubSub]

  # Every change to an event goes to the page, so the inbox table is live.
  pub_sub do
    module ShopWeb.Endpoint
    prefix "pay"
    publish_all :create, "inbox"
    publish_all :update, "inbox"
  end

  postgres do
    table "webhook_events"
    repo Shop.Repo
  end
end

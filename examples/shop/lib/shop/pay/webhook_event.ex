defmodule Shop.Pay.WebhookEvent do
  @moduledoc "Each Stripe webhook, stored once and worked as a job (Mishka Pay's `:inbox`)."

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource],
    notifiers: [Ash.Notifier.PubSub]

  mishka_pay do
    kind :inbox
  end

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

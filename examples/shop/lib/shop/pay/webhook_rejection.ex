defmodule Shop.Pay.WebhookRejection do
  @moduledoc """
  The webhook messages the endpoint refused, counted per provider, site, reason and day (Mishka
  Pay's `:webhook_rejection`); never their bodies.
  """

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource],
    notifiers: [Ash.Notifier.PubSub]

  mishka_pay do
    kind :webhook_rejection
  end

  # Each counted message goes to the page, so the refused count is live.
  pub_sub do
    module ShopWeb.Endpoint
    prefix "pay"
    publish_all :create, "rejections"
  end

  postgres do
    table "webhook_rejections"
    repo Shop.Repo
  end
end

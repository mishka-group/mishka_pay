defmodule Shop.Pay.Inbox do
  @moduledoc "Stores every checked Stripe webhook in `Shop.Pay.WebhookEvent`."
  use MishkaPay.Ash.Inbox.Listener, resource: Shop.Pay.WebhookEvent
end

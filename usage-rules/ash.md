# Rules for the Mishka Pay Ash layer

Optional; compiled only when the host has Ash and AshOban. The host owns its resources, domain,
data layer, policies and notifiers; a fragment brings attributes, identities, calculations and
actions.

```elixir
defmodule MyApp.Pay.WebhookEvent do
  use Ash.Resource, domain: MyApp.Pay, data_layer: AshPostgres.DataLayer,
    fragments: [MishkaPay.Ash.Inbox]
  postgres do
    table "pay_webhook_events"
    repo MyApp.Repo
  end
end

defmodule MyApp.Pay.Payment do
  use Ash.Resource, domain: MyApp.Pay, data_layer: AshPostgres.DataLayer,
    fragments: [MishkaPay.Ash.Payment]
  postgres do
    table "pay_payments"
    repo MyApp.Repo
  end
end

defmodule MyApp.Pay.Subscription do
  use Ash.Resource, domain: MyApp.Pay, data_layer: AshPostgres.DataLayer,
    fragments: [MishkaPay.Ash.Subscription]
  postgres do
    table "pay_subscriptions"
    repo MyApp.Repo
  end
end
```

Listeners (supervise each like a child):

```elixir
defmodule MyApp.Pay.Inbox, do: use MishkaPay.Ash.Inbox.Listener, resource: MyApp.Pay.WebhookEvent
defmodule MyApp.Pay.PaymentSync, do: use MishkaPay.Ash.Payment.Listener, resource: MyApp.Pay.Payment
defmodule MyApp.Pay.SubscriptionSync, do: use MishkaPay.Ash.Subscription.Listener, resource: MyApp.Pay.Subscription
```

Oban with the inbox queue and the cron plugin (AshOban's scheduler):

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [mishka_pay_inbox: 5],
  plugins: [{Oban.Plugins.Cron, []}]

# application children
{Oban, AshOban.config(Application.fetch_env!(:my_app, :ash_domains), Application.fetch_env!(:my_app, Oban))}
```

Generate migrations with `mix ash.codegen <name>` after adding a fragment (and add Oban's own
migration once).

## Actions

| Resource | Action | Args |
|---|---|---|
| Inbox | `:receive` (by the listener) | the event; stored once per provider event id |
| Payment | `:sync` | `provider`, `payment_id`, `tenant` |
| Payment | `:start_checkout` (generic) | `checkout` (the map `MishkaPay.checkout/1` takes) |
| Payment | `:refund` (update) | `amount`, `reason`, `reference` |
| Subscription | `:sync` | `provider`, `subscription_id`, `tenant` |
| Subscription | `:cancel` (update) | `at`: `:period_end` (default) or `:now` |
| Subscription | `:resume` (update) | none |

- Every action asks the provider before its transaction and writes what the provider answered;
  the provider stays the source of truth. A row's tenant is kept from the first sync.
- After each sync, refund, cancel or resume: `mishka_pay:payment:changed` /
  `mishka_pay:subscription:changed` with `%{payment | subscription: struct, record: row}`. The
  host's own Ash notifiers (e.g. `Ash.Notifier.PubSub`) also see every action.
- Errors are Ash errors on their fields (`MishkaPay.Ash.to_ash_error/1`); show
  `MishkaPay.Ash.message(error)`.
- An inbox event whose work fails stays `:pending` with `last_error` set and is tried again (10
  tries), then `:failed`. A host listener on `mishka_pay:event:process` can do its own work per
  event.

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

defmodule MyApp.Pay.Customer do
  use Ash.Resource, domain: MyApp.Pay, data_layer: AshPostgres.DataLayer,
    fragments: [MishkaPay.Ash.Customer]
  postgres do
    table "pay_customers"
    repo MyApp.Repo
  end
end
```

Listeners (supervise each like a child):

```elixir
defmodule MyApp.Pay.Inbox, do: use MishkaPay.Ash.Inbox.Listener, resource: MyApp.Pay.WebhookEvent
defmodule MyApp.Pay.PaymentSync, do: use MishkaPay.Ash.Payment.Listener, resource: MyApp.Pay.Payment
defmodule MyApp.Pay.SubscriptionSync, do: use MishkaPay.Ash.Subscription.Listener, resource: MyApp.Pay.Subscription
defmodule MyApp.Pay.CustomerSync, do: use MishkaPay.Ash.Customer.Listener, resource: MyApp.Pay.Customer
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

## Many sites (Mishka CMS)

A resource may carry Ash multitenancy on the host's own attribute; then each action runs with the
site as Ash's tenant, the provider's keys are read for that site, and each webhook's row is synced
inside the site its URL names (`/pay/webhooks/stripe/<site id>`). The row's `:tenant` keeps it for
later actions. Keep the webhook inbox global (no multitenancy): a webhook comes before any site is
chosen.

```elixir
defmodule MyApp.Pay.Payment do
  use Ash.Resource, domain: MyApp.Pay, data_layer: AshPostgres.DataLayer,
    fragments: [MishkaPay.Ash.Payment]

  attributes do
    attribute :site_id, :uuid, allow_nil?: false, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
  end
end

Ash.create(MyApp.Pay.Payment, %{provider: "stripe", payment_id: "pi_..."},
  action: :sync, tenant: site.id)
```

The same provider object in two sites is two rows, one per site (`MishkaPay.Ash.Tenant`).

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
| Subscription | `:change` (update) | `price_id`, `quantity`, `item_id`, `proration`, `proration_date`, `billing_cycle_anchor`, `payment_behavior` |
| Subscription | `:pause` (update) | `behavior` (`:void` default), `resumes_at` |
| Subscription | `:resume_collection` (update) | none |
| Dispute | `:sync` | `provider`, `dispute_id`, `tenant` |
| Dispute | `:submit_evidence` (update) | `evidence` (the provider's field names), `submit` |
| Dispute | `:accept` (update) | none |
| Customer | `:register` | `provider`, `tenant`, `email`, `name`, `phone`, `reference`, `metadata` |
| Customer | `:sync` | `provider`, `customer_id`, `tenant`; a deleted customer gets `deleted_at` |
| Customer | `:edit` (update) | `email`, `name`, `phone`, `metadata` |
| Customer | `:portal` (generic) | `id` (the row's), `return_url`, `configuration`; answers `MishkaPay.PortalSession` |

- Every action asks the provider before its transaction and writes what the provider answered;
  the provider stays the source of truth. A row's tenant is kept from the first sync.
- After each sync, refund, cancel, resume, register or edit: `mishka_pay:payment:changed` /
  `mishka_pay:subscription:changed` / `mishka_pay:customer:changed` with
  `%{payment | subscription | customer: struct, record: row}`. The
  host's own Ash notifiers (e.g. `Ash.Notifier.PubSub`) also see every action.
- Errors are Ash errors on their fields (`MishkaPay.Ash.to_ash_error/1`); show
  `MishkaPay.Ash.message(error)`.
- An inbox event whose work fails stays `:pending` with `last_error` set and is tried again (10
  tries), then `:failed`. A host listener on `mishka_pay:event:process` can do its own work per
  event.

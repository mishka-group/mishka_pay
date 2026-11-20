# Rules for the Mishka Pay Ash layer

Optional; compiled only when the host has Ash (and AshOban for the inbox). The host owns its
resources, domain, data layer, policies and notifiers; the `MishkaPay.Ash.Resource` extension adds
to each resource the attributes, identities, calculations, actions, code interface and webhook
listener of its kind; never write these by hand.

```elixir
defmodule MyApp.Pay.WebhookEvent do
  use Ash.Resource, domain: MyApp.Pay, data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :inbox
  end

  postgres do
    table "pay_webhook_events"
    repo MyApp.Repo
  end
end

defmodule MyApp.Pay.Subscription do
  use Ash.Resource, domain: MyApp.Pay, data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :subscription                     # :inbox | :payment | :subscription | :customer | :dispute
    actions [:sync, :cancel]               # optional; default: every action of the kind
    listen? true                           # default: <Resource>.MishkaPayListener is made
    announce? true                         # default: mishka_pay:subscription:changed after writes
    code_interface? true                   # default: MyApp.Pay.Subscription.cancel!(row, %{at: :now})
    belongs_to_user MyApp.Accounts.User    # optional: belongs_to :user on :user_id, filled from the checkout's owner
    # belongs_to_user {MyApp.Accounts.User, attribute: :owner_id}
    # tenant_from :site_id                 # optional: the host's own site column, without Ash multitenancy
  end

  postgres do
    table "pay_subscriptions"
    repo MyApp.Repo
  end
end
```

- One resource per kind you keep: `:payment`, `:subscription`, `:customer`, `:dispute` the same
  way, each with its own table.
- What the host defines itself is kept: an attribute, identity, calculation, action, relationship
  or code interface of the same name is never added again (change a type that way).
- An action the kind does not have, an `:inbox` without all of its actions, or an `:inbox`
  without AshOban is a compile error.
- `MishkaPay.Ash.Resource.Info` reads the setup back: `mishka_pay_kind/1`, `actions/1`,
  `listener/1`.

Supervise the listeners of the domain (no hand-written listener modules):

```elixir
children = [MishkaPay.Providers.Stripe, MyApp.Pay.Keys] ++ MishkaPay.Ash.listeners(MyApp.Pay)
```

The inbox's listener must come before any other `mishka_pay:webhook:received` listener that may
fail an event: put the inbox resource first in the domain, or the listeners before such plugins.

Oban with the inbox queue and the cron plugin (AshOban's scheduler). The inbox's worker and
scheduler are `<Resource>.MishkaPayWorker` and `<Resource>.MishkaPayScheduler`.

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [mishka_pay_inbox: 5],
  plugins: [{Oban.Plugins.Cron, []}]

# application children
{Oban, AshOban.config(Application.fetch_env!(:my_app, :ash_domains), Application.fetch_env!(:my_app, Oban))}
```

Generate migrations with `mix ash.codegen <name>` after adding a resource (and add Oban's own
migration once). For a data layer that checks no identity itself (ETS), define the kind's identity
yourself with `pre_check_with`.

## Many sites (Mishka CMS)

- A CMS extension lists `MishkaPay.Ash.listeners(MyExtension.Pay)` in its application's
  `plugins/0` and children (the CMS checks every plugin is started by its application), and adds
  `mishka_pay_inbox` to Oban's queues.

A resource may carry Ash multitenancy on the host's own attribute; then each action runs with the
site as Ash's tenant, the provider's keys are read for that site, and each webhook's row is synced
inside the site its URL names (`/pay/webhooks/stripe/<site id>`). The row's `:tenant` keeps it for
later actions. Keep the webhook inbox global (no multitenancy): a webhook comes before any site is
chosen.

```elixir
defmodule MyApp.Pay.Payment do
  use Ash.Resource, domain: MyApp.Pay, data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :payment
  end

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

## What the rows hold

- Payment rows: `checkout_id`, `price_ids`, `product_ids` (what was sold), `charge_id` and
  `balance_transaction_id` (join a `MishkaPay.Balance.Transaction` to its row by these, or by its
  `:payment_id`, never by amount and time). Subscription rows:
  `price_ids`, `product_ids`, calculations `active?`, `on_trial?`, `canceling?`.
- Kind attributes are `writable?: false`: never put them in an action's `accept`; write your own
  attributes beside them.
- A `:sync` that read the provider before a newer sync wrote is skipped (`MishkaPay.Ash.stale?/1`
  on its error); the listeners count it as done.
- `:resync` (update, no arguments) on every provider kind reads the row again; `resync_after 6`
  adds an hourly trigger for rows still open (pending payments, live subscriptions, open disputes,
  draft or open bills).
- Read-only generic actions: payment `:refunds`, subscription `:upcoming_invoice` and
  `:preview_change` (the `:change` arguments), each with the row's `id`.
- `:register` with a `reference` reuses the site's customer for it.
- `keep_events_for 30` (inbox, default): processed events are deleted daily; `:forever` keeps them.
- Inbox telemetry: `[:mishka_pay, :inbox, :process, :stop]` (`:outcome`, `:lag`) and
  `[:mishka_pay, :inbox, :failed]`.

## Access: who has a subscription

- `belongs_to_user` on the payment and subscription resources: `:start_checkout` sends the actor
  as the checkout's `owner`; the provider keeps it; every sync writes it into the user attribute.
  Pass `owner:` in the checkout map to buy for someone else. A customer's `:register` accepts the
  user attribute.
- Gate access with the policy check, never with a hand-written status test:

```elixir
authorize_if {MishkaPay.Ash.Subscribed, resource: MyApp.Pay.Subscription}
authorize_if {MishkaPay.Ash.Subscribed, resource: MyApp.Pay.Subscription, product: ["prod_pro"]}
# price: ..., statuses: [:active, :trialing, :past_due]
MishkaPay.Ash.subscribed?(MyApp.Pay.Subscription, user, tenant: site.id)
```

- Access: `:active`, or `:trialing` until `trial_end`. One query per check. The row keeps
  `price_ids` and `product_ids` for the tier options.
- Mishka Pay has no admin pages: a host shows the resources and their actions with mishka_gervaz,
  in the site's tenant, under its own policies.

## Actions

| Resource | Action | Args |
|---|---|---|
| Inbox | `:receive` (by the listener) | the event; stored once per provider event id |
| Inbox | `:process`, `:note_error`, `:fail` (by its AshOban trigger) | none; `fail` takes `error` |
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
| Customer | `:register` | `provider`, `tenant`, `api` (`:v2`/`:v1`, else the keys' `customer_api`), `email`, `name`, `phone`, `reference`, `metadata`; the user attribute with `belongs_to_user` |
| Customer | `:sync` | `provider`, `customer_id`, `tenant`; a deleted customer gets `deleted_at` |
| Customer | `:edit` (update) | `email`, `name`, `phone`, `metadata` |
| Customer | `:remove` (update) | none; deletes it at the provider for good and sets `deleted_at` (destroy the row too to erase the host's copy) |
| Product | `:sync`; `:add` (`provider`, `tenant`, `name`, `description`, `tax_code`, `id`, `metadata`); `:edit`; `:archive` | |
| Price | `:sync`; `:add` (`product_id`, `amount` map, `interval`, `interval_count`, `tax_behavior`, `lookup_key`, `metadata`); `:archive` | |
| Coupon | `:sync`; `:add` (`id`, `name`, `percent_off` or `amount_off` map, `duration`...); `:remove` (sets `deleted_at`) | |
| Promotion code | `:sync`; `:add` (`coupon_id`, `code`, limits); `:edit` (`active`, `metadata`) | |
| Payment link | `:sync`; `:add` (`link` map); `:edit` (`changes` map) | |
| Invoice | `:sync`; `:add` (`draft` map); `:finalize`, `:send`, `:pay` (`out_of_band`), `:void`, `:mark_uncollectible`, `:remove` | |
| Customer | `:portal` (generic) | `id` (the row's), `return_url`, `configuration`; answers `MishkaPay.PortalSession` |

- Every action asks the provider before its transaction and writes what the provider answered;
  the provider stays the source of truth. A row's tenant is kept from the first sync.
- After each sync, refund, cancel, resume, register or edit (unless `announce? false`):
  `mishka_pay:payment:changed` / `mishka_pay:subscription:changed` / `mishka_pay:customer:changed`
  / `mishka_pay:dispute:changed` with `%{payment | subscription | customer | dispute: struct,
  record: row}`. The
  host's own Ash notifiers (e.g. `Ash.Notifier.PubSub`) also see every action.
- Every resource also gets the primary `:read`; with `code_interface? true` each action is a
  function of the resource named like it (`receive_event` for the inbox's `:receive`).
- Errors are Ash errors on their fields (`MishkaPay.Ash.to_ash_error/1`); show
  `MishkaPay.Ash.message(error)`. `MishkaPay.Ash.provider_error(error)` gives the provider's own
  `Rejected` or `Declined` inside, with its `request_id` for the log and the provider's support.
- An inbox event whose work fails stays `:pending` with `last_error` set and is tried again (10
  tries), then `:failed`. A host listener on `mishka_pay:event:process` can do its own work per
  event.

## Further reading

The Mishka Pay docs on mishka.tools explain each area with full examples:

- [Keep payments in Ash resources and Mishka CMS](https://mishka.tools/pay/docs/ash-and-cms)

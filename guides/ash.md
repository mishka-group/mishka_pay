# The Ash layer

> On the web, with more detail: [Keep payments in Ash resources and Mishka CMS](https://mishka.tools/pay/docs/ash-and-cms).

With Ash, Mishka Pay keeps payments, subscriptions, customers and disputes in your own resources,
read again from the provider whenever a webhook says something changed, and stores every webhook
in an inbox worked by AshOban with retries.

```elixir
defmodule MyApp.Pay.Payment do
  use Ash.Resource, domain: MyApp.Pay, data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :payment
  end

  postgres do
    table "pay_payments"
    repo MyApp.Repo
  end
end
```

`mix igniter.install mishka_pay --ash` writes the domain and the five resources (inbox, payment,
subscription, customer, dispute), then `mix ash.codegen mishka_pay`. Each resource makes its own
listener (`<Resource>.MishkaPayListener`), which the installer adds to the application's children;
by hand, `MishkaPay.Ash.listeners(MyApp.Pay)` lists them all in the domain's order.

## What each kind does

- **inbox**: stores each verified webhook once and works it with retries (10 tries, the reason of
  each failure kept on the row).
- **payment**: `:sync` reads a payment from the provider; `:start_checkout`; `:refund`;
  `:refunds` (read-only: the row's refunds).
- **subscription**: `:sync`, `:cancel`, `:resume`, `:change` (plan or quantity, with proration),
  `:pause`, `:resume_collection`; read-only `:upcoming_invoice` and `:preview_change`.
- Every provider object's kind has `:resync`, which reads its row again (an admin's refresh), and
  `resync_after: hours` reads open rows again every hour when no webhook came.
- A customer's `:register` reads again the customer the site already has for that `reference`
  instead of making a second one, so it is safe to call on every purchase.
- **customer**: `:register`, `:sync`, `:edit`, `:portal`.
- **dispute**: `:sync`, `:submit_evidence`, `:accept`.
- **product**: `:sync`, `:add`, `:edit`, `:archive`. **price**: `:sync`, `:add`, `:archive`.
- **coupon**: `:sync`, `:add`, `:remove`. **promotion_code**: `:sync`, `:add`, `:edit`.
- **payment_link**: `:sync`, `:add` (`link`, the map `MishkaPay.create_payment_link/1` takes),
  `:edit` (`changes`).
- **invoice**: `:sync`, `:add` (`draft`, a `MishkaPay.Invoice.Draft` map), `:finalize`, `:send`,
  `:pay` (`out_of_band`), `:void`, `:mark_uncollectible`, `:remove` (a draft).

The last six are what a site manages from its admin. Each keeps a local copy that its webhooks
(`product.*`, `price.*`, `coupon.*`, `promotion_code.*`, `payment_link.*`, `invoice.*`) keep
current, and fires `mishka_pay:<kind>:changed` (`MishkaPay.Events.changed/1`) after each write.

Every action asks the provider before its transaction and writes what the provider answered, then
fires `mishka_pay:<kind>:changed`. The `mishka_pay` section takes `actions`, `listen?`,
`announce?`, `code_interface?`, `belongs_to_user` and `tenant_from`; see `MishkaPay.Ash.Resource`
and its DSL page.

## Who paid, and who has access

With `belongs_to_user`, a payment or a subscription row knows its user. `:start_checkout` names
the actor as the checkout's owner; the provider keeps the owner on the payment or the
subscription, and every sync, from an action or a webhook, writes it into the user attribute.

`MishkaPay.Ash.Subscribed` is the policy check for what a subscription unlocks, such as
members-only posts or files sold by plan, and `MishkaPay.Ash.subscribed?/3` asks the same in code:

```elixir
policies do
  policy action(:read) do
    authorize_if {MishkaPay.Ash.Subscribed, resource: MyApp.Pay.Subscription}
  end

  policy action(:download) do
    authorize_if {MishkaPay.Ash.Subscribed, resource: MyApp.Pay.Subscription, product: "prod_pro"}
  end
end

MishkaPay.Ash.subscribed?(MyApp.Pay.Subscription, current_user, tenant: site.id)
```

Access is `:active`, or `:trialing` until the trial ends; `statuses: [:active, :trialing,
:past_due]` keeps it while the provider retries a failed renewal. Each check is one query, so a
cancel a webhook brought counts at once. In a multi-tenant resource it reads the action's site.

## What the rows hold

- A payment row keeps `checkout_id`, `price_ids` and `product_ids`: what its checkout sold, for a
  shop to deliver.
- A subscription row keeps `price_ids` and `product_ids`, and has the calculations `active?`,
  `on_trial?` and `canceling?`, usable in filters, sorts and admin tables.
- The provider's fields are never an action's input: a host's `accept :*` takes only its own
  attributes, and every write comes from the provider's word.
- Two syncs of one object can run at once (a webhook and an action); the row keeps the newer read.
- The inbox forgets processed events after `keep_events_for` days (30), with a daily AshOban
  trigger; failed ones stay.

## Your own admin pages

Mishka Pay has no admin page of its own. Every call is an Ash action on your resources, run in
the site's tenant, so an admin built with mishka_gervaz (or any Ash UI) lists, filters and acts
on them like any other resource: the rows are read with the primary `:read`, and the buttons are
the kind's actions (`:refund`, `:cancel`, `:submit_evidence`...). Put your own policies on them.

## Real time

```elixir
defmodule MyApp.Pay.Broadcast do
  use MishkaPay.PubSub, pubsub: MyApp.PubSub
end
```

Each change goes to `MishkaPay.PubSub.topic(kind)` and `MishkaPay.PubSub.topic(kind, site_id)`.

# The Ash layer

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
- **payment**: `:sync` reads a payment from the provider; `:start_checkout`; `:refund`.
- **subscription**: `:sync`, `:cancel`, `:resume`, `:change` (plan or quantity, with proration),
  `:pause`, `:resume_collection`.
- **customer**: `:register`, `:sync`, `:edit`, `:portal`.
- **dispute**: `:sync`, `:submit_evidence`, `:accept`.

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

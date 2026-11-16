# Mishka Pay

A payment SDK for Elixir: checkouts, payments, refunds, subscriptions with plan changes, customers
and their billing portal, coupons and promotion codes, a product catalog, payment links, disputes
and verified webhooks, the same way for every provider. Stripe is the full provider; PayPal's
adapter is coming.

- **Providers are plugins.** A provider is a [mishka_installer](https://github.com/mishka-group/mishka_installer)
  plugin that implements `MishkaPay.Provider`; anyone can add their own.
- **Many sites, one install.** Every call names its tenant (a site), and the keys come from the
  project at runtime, per site: a multi-tenant CMS such as Mishka CMS gives each site its own
  Stripe account.
- **On its own or inside Ash.** The core works on plain structs built with
  [guarded_struct](https://github.com/mishka-group/guarded_struct). With [Ash](https://ash-hq.org),
  the `MishkaPay.Ash` layer keeps payments, subscriptions, customers and disputes in the project's
  own resources, kept current from webhooks, with Ash multitenancy.
- **Every extension point is an event.** Keys, checks before a checkout and what happens after a
  payment are mishka_installer events; `MishkaPay.PubSub` broadcasts every change in one line.

## Five minutes

```bash
mix igniter.install mishka_pay
```

It adds the Stripe provider, a keys plugin, the webhook endpoint before `Plug.Parsers` and the test
config. Give it a test key and sell:

```bash
export STRIPE_SECRET_KEY=sk_test_...
```

```elixir
{:ok, checkout} =
  MishkaPay.checkout(%{
    provider: "stripe",
    items: [%{name: "Elixir ebook", amount: %{amount: "19.99", currency: "USD"}}],
    success_url: url(~p"/thanks") <> "?session_id={CHECKOUT_SESSION_ID}",
    cancel_url: url(~p"/cart"),
    reference: order.id
  })

redirect(conn, external: checkout.url)
```

Then read the [getting started guide](guides/getting-started.md). An agent writing payment code
reads `usage-rules.md`.

## Guides

- [Getting started](guides/getting-started.md): keys per site, a checkout, reading the payment back.
- [Webhooks](guides/webhooks.md): the endpoint, which Stripe events change what, listeners.
- [The Ash layer](guides/ash.md): payments, subscriptions, customers and disputes as your resources.
- [Many sites](guides/multi-tenant.md): one install for a multi-tenant project.
- [Testing](guides/testing.md): stubs, signed webhooks, Stripe's mock server and test clocks.
- [Errors](guides/errors.md): what each error means and what to show.
- [Telemetry](guides/telemetry.md): every event and its metadata.
- [Production checklist](guides/production.md): live keys, webhooks per site, Managed Payments.

## The demo

`examples/shop` is a Phoenix shop on the Stripe sandbox that shows every feature, each part with a
`data-testid` for browser tests.

## License

Apache-2.0. See [LICENSE](LICENSE).

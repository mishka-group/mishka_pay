# Mishka Pay demo shop

A one-page Phoenix app that runs Mishka Pay against **your Stripe sandbox**. Buy a product, see
every payment, refund one, and change the site's payment settings while it runs.

It lives in `examples/` and is not part of the `mishka_pay` package.

## What it shows

Every part of the page carries a `data-testid`, so a browser test (Playwright or another) finds it
without leaning on text or layout.

| On the page | What Mishka Pay does |
|---|---|
| **Providers**, **Site demo**, **Plugins** | `MishkaPay.Provider.all/0`; the site's keys and settings from `MishkaPay.Credentials.fetch/2` (never a key); every plugin on Mishka Pay's events |
| **Buy with Stripe** + options | `:start_checkout` for a product from the seeds: quantity 1 to 10, buyer email, merchant of record and metadata for this checkout |
| Shop closed | the checkout gate (`Shop.Pay.Gate` on `mishka_pay:checkout:before`) refuses every checkout |
| Back from Stripe, or canceled | `MishkaPay.fetch_checkout/3` reads the session, `:sync` keeps the payment at once |
| **Payments**: totals, status filter, live | the stored rows with buyer, card and failure reason; webhook → inbox → job → sync → `mishka_pay:payment:changed` → the page |
| **Details** of a payment | the stored row beside `MishkaPay.fetch_payment/3` live from Stripe: buyer, card, receipt, failure, description, metadata and every refund; its webhook events; sync; refund with an amount and a reason |
| **Read payment** / **Read a checkout back** | any sandbox payment or checkout by its id; a checkout shows its total, tax and buyer email |
| **Webhook simulator** | a Stripe event about a payment, signed as Stripe signs (or with a bad signature), sent to the shop's own webhook endpoint |
| **Webhook inbox**, **Telemetry**, live | each event stored once and worked as an Oban job; every Mishka Pay call and HTTP request with its outcome and time |
| **Site settings** | refund rule, merchant of record and shop open or closed, in the database, read on every call |

## Run it

You need Postgres and a Stripe sandbox secret key (Stripe dashboard → Developers → API keys).

Put the key in `examples/shop/.env` (it is in `.gitignore`, so it never reaches GitHub):

```bash
STRIPE_SECRET_KEY=sk_test_...
```

Then:

```bash
cd examples/shop
mix setup
mix phx.server
```

The app reads `.env` itself; a variable set in the shell wins over the file. `mix setup` also runs
the seeds (`priv/repo/seeds.exs`): the products and the site's settings.

### Test payments in every status

```bash
mix shop.sandbox           # 17 payments: paid, part refunded, refunded, declined, 3D Secure, waiting, canceled
mix shop.sandbox resync    # reads every stored payment from Stripe again
```

It runs only with a test key, makes each payment with one of Stripe's test cards, and saves and
refunds them through Mishka Pay's own `:sync` and `:refund`.

Open <http://localhost:4000>. Pay with the test card `4242 4242 4242 4242`, any future date, any CVC.

Postgres on another port: `export POSTGRES_PORT=5433`.

### Webhooks

The **Webhook simulator** on the page sends signed test events with no setup. For Stripe's real
events (a refund made in the dashboard, a late payment), forward them with the
[Stripe CLI](https://docs.stripe.com/stripe-cli):

```bash
stripe listen --forward-to localhost:4000/pay/webhooks/stripe/demo
export STRIPE_WEBHOOK_SECRET=whsec_...   # the secret `stripe listen` prints
```

`demo` is the site (tenant) the shop runs as; each site of a multi-site project has its own URL.

## Where to look

- `lib/shop/pay/`: the Ash resources (`Payment`, `WebhookEvent`, `Setting`), the plugins
  (`Keys`, `Gate`, `Inbox`, `PaymentSync`, `LiveFeed`), the telemetry feed, the stats and the
  webhook simulator.
- `lib/shop/catalog/` and `priv/repo/seeds.exs`: the products.
- `lib/mix/tasks/shop.sandbox.ex`: the test payments.
- `lib/shop/application.ex`: Stripe and the plugins are supervised like any child.
- `lib/shop_web/endpoint.ex`: `plug MishkaPay.Webhook` before the parsers.
- `lib/shop_web/live/shop_live.ex` and `lib/shop_web/components/pay_components.ex`: the page.

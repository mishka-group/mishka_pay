# Mishka Pay demo shop

A one-page Phoenix app that runs Mishka Pay against **your Stripe sandbox**. Buy a product, see
every payment, refund one, and change the site's payment settings while it runs.

It lives in `examples/` and is not part of the `mishka_pay` package.

## What it shows

| On the page | What Mishka Pay does |
|---|---|
| **Installed providers** | `MishkaPay.Provider.all/0`: each provider and its capabilities |
| **Site demo** | `MishkaPay.Credentials.fetch/2`: mode, refund rule, merchant of record, webhook secret (never a key) |
| **Buy with Stripe** + options | `:start_checkout`: quantity, buyer email, merchant of record and metadata for this checkout |
| Closed shop | the checkout gate (`Shop.Pay.Gate` on `mishka_pay:checkout:before`) refuses every checkout |
| Back from Stripe, or canceled | `MishkaPay.fetch_checkout/3` reads the session, `:sync` keeps the payment at once |
| **Payments**, live | webhook → inbox → job → payment row → `mishka_pay:payment:changed` → the page |
| **Details** of a payment | the shop's row and `MishkaPay.fetch_payment/3` live from Stripe, side by side, with its webhook events |
| **Refund** (all or an amount, with a reason) | `:refund`, once or many times as the site's setting says |
| **Read payment** / **Read a checkout back** | pull any sandbox payment or checkout in by its id |
| **Webhook inbox**, live | each Stripe event stored once, worked as an Oban job, with its status and error |
| **Telemetry**, live | every Mishka Pay call and HTTP request with its outcome and time |
| **Site settings** | refund rule, merchant of record and shop open/closed, in the database, read on every call |

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

The app reads `.env` itself; a variable set in the shell wins over the file.

Open <http://localhost:4000>. Pay with the test card `4242 4242 4242 4242`, any future date, any CVC.

Postgres on another port: `export POSTGRES_PORT=5433`.

### Live updates from Stripe (optional)

Without webhooks the page still shows each payment when you come back from Stripe. To get every
change (a refund made in the dashboard, a late payment), forward Stripe's webhooks with the
[Stripe CLI](https://docs.stripe.com/stripe-cli):

```bash
stripe listen --forward-to localhost:4000/pay/webhooks/stripe/demo
export STRIPE_WEBHOOK_SECRET=whsec_...   # the secret `stripe listen` prints
```

`demo` is the site (tenant) the shop runs as; each site of a multi-site project has its own URL.

## Where to look

- `lib/shop/pay/`: the Ash resources (`Payment`, `WebhookEvent`, `Setting`), the plugins
  (`Keys`, `Gate`, `Inbox`, `PaymentSync`, `LiveFeed`) and the telemetry feed.
- `lib/shop/application.ex`: Stripe and the plugins are supervised like any child.
- `lib/shop_web/endpoint.ex`: `plug MishkaPay.Webhook` before the parsers.
- `lib/shop_web/live/shop_live.ex` and `lib/shop_web/components/pay_components.ex`: the page.

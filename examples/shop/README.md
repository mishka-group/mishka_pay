# Mishka Pay demo shop

A one-page Phoenix app that runs Mishka Pay against **your Stripe sandbox**. Buy a product, see
every payment, refund one, and change the site's payment settings while it runs.

It lives in `examples/` and is not part of the `mishka_pay` package.

## What it shows

| On the page | What Mishka Pay does |
|---|---|
| **Buy with Stripe** | `:start_checkout` opens a Stripe Checkout page |
| Back from Stripe | `MishkaPay.fetch_checkout/3` reads the session, `:sync` keeps the payment at once |
| **Payments** table, live | webhook → inbox → job → payment row → `mishka_pay:payment:changed` → the page |
| **Last bought** | the newest payment, updated live |
| **Refund** (all, or an amount) | `:refund`, once or many times as the site's setting says |
| **Read from Stripe** | pulls an older sandbox payment in by its `pi_...` id |
| **Site settings** | refund rule and merchant of record, stored in the database and read on every call |

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

- `lib/shop/pay/`: the Ash resources (`Payment`, `WebhookEvent`, `Setting`) and the plugins
  (`Keys`, `Inbox`, `PaymentSync`, `LiveFeed`).
- `lib/shop/application.ex`: Stripe and the plugins are supervised like any child.
- `lib/shop_web/endpoint.ex`: `plug MishkaPay.Webhook` before the parsers.
- `lib/shop_web/live/shop_live.ex`: the page.

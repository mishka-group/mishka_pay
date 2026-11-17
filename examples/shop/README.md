# Mishka Pay demo shop

A Phoenix app that runs Mishka Pay against **your Stripe sandbox**. Buy a product, see
every payment, refund one, and change the site's payment settings while it runs.

It lives in `examples/` and is not part of the `mishka_pay` package.

## What it shows

Every part of the page carries a `data-testid`, so a browser test (Playwright or another) finds it
without leaning on text or layout.

| On the page | What Mishka Pay does |
|---|---|
| **Providers**, **Site demo**, **Plugins** | `MishkaPay.Provider.all/0`; the site's keys and settings from `MishkaPay.Credentials.fetch/2` (never a key); every plugin on Mishka Pay's events |
| **Pay with**: Stripe (PayPal coming soon) | the checkout through the chosen provider |
| **Buy with Stripe** + options | `:start_checkout` for a product from the seeds: quantity 1 to 10, buyer email, merchant of record and metadata for this checkout |
| Shop closed | the checkout gate (`Shop.Pay.Gate` on `mishka_pay:checkout:before`) refuses every checkout |
| Back from Stripe, or canceled | `MishkaPay.fetch_checkout/3` reads the session, `:sync` keeps the payment at once |
| **Payments**: totals, status filter, live | the stored rows with buyer, card and failure reason; webhook → inbox → job → sync → `mishka_pay:payment:changed` → the page |
| **Details** of a payment | the stored row beside `MishkaPay.fetch_payment/3` live from Stripe: buyer, card, receipt, failure, description, metadata and every refund; its webhook events; sync; refund with an amount and a reason |
| **Plans**: Subscribe with Stripe | a checkout in `mode: :subscription` with the plan's interval and trial |
| **Subscriptions**, live | `Shop.Pay.Subscription` rows (`mishka_pay do kind :subscription end`); details beside `MishkaPay.fetch_subscription/3` and its invoices (`MishkaPay.list_invoices/3`); cancel at the period's end or now, keep it going, sync; a new plan or quantity with **Preview the bill** (`MishkaPay.preview_subscription_change/1`) then **Apply** (`:change`); pause and resume collection |
| **Read payment** / **Read a checkout back** | any sandbox payment or checkout by its id; a checkout shows its total, tax and buyer email |
| **Webhook simulator** | a Stripe event about a payment or subscription in nine situations, each with the answer the endpoint must give: good (200), bad signature, too old, a site with no keys (400), no such provider (404), GET (405), over 1 MB (413), a listener fails (500), the same event twice (200 and 200, stored once) |
| **Test clocks** | a subscription on its own Stripe test clock (card works, fails at renewal, trial then paid, trial then fails), moved forward a day to a year; the subscription is synced when Stripe is done |
| **Webhook inbox**, **Telemetry**, live | each event stored once and worked as an Oban job; every Mishka Pay call and HTTP request with its outcome and time |
| **Site settings** | refund rule, merchant of record, Stripe Tax and shop open or closed, in the database, read on every call |
| **Sell a product with one link** (`/sell`, the top card) | one button runs `MishkaPay.create_product/1`, `create_price/1` and `create_payment_link/1` with every Stripe field, shows each call, and ends on the buyer's link; **Undo all of it** turns the link off and archives the price and product |
| **Payment links** | `MishkaPay.create_payment_link/1` with a purchase limit (one-time, limited or none), quantity range, trial, invoice and tax choices; `PaymentLink.url/2` for one buyer; turn off or change it (`update_payment_link/1`); the list from `list_payment_links/3` |
| **Catalog** | the shop's products beside their Stripe product and prices (`create_product/1`, `create_price/1`, `archive_price/3`) |
| **Customers** | `Shop.Pay.Customer` rows: register, edit, sync, open Stripe's customer portal (`:portal`) |
| **Coupons** and promotion codes | `MishkaPay.create_coupon/1` (percent or amount, once, repeating or forever, a use limit) and `create_promotion_code/1` (for one customer only, first order, a minimum, an end date, a use limit) |
| **Disputes**, live | `Shop.Pay.Dispute` rows from `charge.dispute.*` webhooks or **Read disputes**; evidence (`:submit_evidence`) and **Accept the loss** (`:accept`). Pay with 4000 0000 0000 0259 to make one |
| **Members and access** | sign in by email (`Shop.Accounts.Member`, a demo with no password, kept in the session); a plan bought while signed in runs `:start_checkout` with the member as the actor, so the subscription belongs to them (`belongs_to_user`); the members-only post opens when `MishkaPay.Ash.subscribed?/3` says so; the member's rows with `active?`, `on_trial?` and `canceling?` |
| **Refunds and held payments** | per payment row, **Refunds** runs the generic `:refunds` action; a pay-later payment (`:authorized`) is taken, all or part, with `MishkaPay.capture_payment/4` or let go with `cancel_payment/3`; one refund read by its id (`fetch_refund/3`) |
| **Checkout options** | phone, terms, up to three questions (text, numbers, dropdown), description, card statement suffix (refused while merchant of record is on), the pay button's word, a trial without a card, shipping countries and an inline rate, pay later (`capture: :manual`); on Stripe's page or embedded in this one (`ui_mode: :embedded`, mounted by Stripe.js); **Read it back** shows the phone, answers, terms, shipping address and items sold |
| **Saved cards and portal links** | a setup checkout (`mode: :setup`) saves a card without charging; the customer's cards (`list_payment_methods/3`), made default or taken off; Stripe's portal opened on one task (`portal_session/1` with `flow:`): update the card, cancel or change a subscription |
| **One-off bills** | `MishkaPay.create_invoice/1` for a customer, then finalize, email, mark paid by other means, void, mark uncollectible or delete, with the status, number, page and PDF after each step |
| **Find customers, preview bills** | `search_customers/3` by email, name or reference; a subscription's next bill (`:upcoming_invoice`) and a plan or quantity change's bill (`:preview_change`) |
| Every list, live in every tab | `Shop.Pay.Broadcast` (`use MishkaPay.PubSub`) sends each change to the site's topic, and every open page updates |

## Run it

You need Postgres and the secret key of a **Stripe Sandbox**: in the Stripe Dashboard open the
account menu → **Sandboxes** → **Create sandbox**, switch to it, then Developers → API keys.
Develop on a Sandbox, not on your account's test mode: a Sandbox is its own isolated account, and
some flows (Accounts v2 onboarding for sellers that take transfers) only run there. Never put a
live key here.

Put the key in `examples/shop/.env` (it is in `.gitignore`, so it never reaches GitHub):

```bash
STRIPE_SECRET_KEY=sk_test_...
# Only for the embedded checkout: the publishable key, which Stripe.js gets in the page.
STRIPE_PUBLISHABLE_KEY=pk_test_...
```

Then:

```bash
cd examples/shop
mix setup
mix phx.server
```

The app reads `.env` itself; a variable set in the shell wins over the file. `mix setup` also runs
the seeds (`priv/repo/seeds.exs`): the products and the site's settings.

### PayPal: coming soon

Mishka Pay's PayPal adapter is in and tested against a stand-in; its run against PayPal's sandbox
waits for a PayPal sandbox app ([#17](https://github.com/mishka-group/mishka_pay/issues/17)). Until
then "Pay with: PayPal" is off in the demo.

### Test payments in every status

```bash
mix shop.sandbox                 # 17 payments in every status, then 4 subscriptions
mix shop.sandbox subscriptions   # only the subscriptions: active, in trial, ending, canceled
mix shop.sandbox resync          # reads every stored payment from Stripe again
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

After rolling the endpoint's secret in Stripe, put the new one in `STRIPE_WEBHOOK_SECRET` and the
old one in `STRIPE_WEBHOOK_SECRET_OLD` (several with commas) until Stripe stops signing with it:
both are accepted. In `.env` (one `NAME=value` per line, no comment after the value):

```bash
STRIPE_WEBHOOK_SECRET=whsec_new...
STRIPE_WEBHOOK_SECRET_OLD=whsec_old...,whsec_older...
```

`.env` is read when the shop starts, and a variable set in the shell wins over it; restart
`mix phx.server` after changing it. The Site card always says how many older secrets are still
taken (`0` when none). The simulator offers "Signed with the secret before a roll" whenever there
is one: with `STRIPE_WEBHOOK_SECRET_OLD` set, or when `STRIPE_WEBHOOK_SECRET` is not set at all
and the simulator signs with its own secret, whose own old one stands in. With a `stripe listen`
secret and no `STRIPE_WEBHOOK_SECRET_OLD` there is no old secret, so that situation is not
offered.

## Where to look

- `lib/shop/pay/`: the Ash resources (`Payment`, `WebhookEvent`, `Setting`), the plugins
  (`Keys`, `Gate`, `Inbox`, `PaymentSync`, `LiveFeed`), the telemetry feed, the stats and the
  webhook simulator.
- `lib/shop/catalog/` and `priv/repo/seeds.exs`: the products.
- `lib/mix/tasks/shop.sandbox.ex`: the test payments.
- `lib/shop/application.ex`: Stripe and the plugins are supervised like any child.
- `lib/shop_web/endpoint.ex`: `plug MishkaPay.Webhook` before the parsers.
- `lib/shop_web/live/shop_live.ex` and `lib/shop_web/components/pay_components.ex`: the page.

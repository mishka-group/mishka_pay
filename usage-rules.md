# Rules for working with Mishka Pay

Mishka Pay (`:mishka_pay`) takes payments in Elixir projects: checkouts, payments, refunds,
subscriptions and verified webhooks, the same way for every provider. Stripe is the full provider;
PayPal's adapter exists and waits for its sandbox run. An optional Ash layer stores events,
payments and subscriptions in the host's own resources.

Read this file before writing any code that touches payments. Then load the sub-rule for the area
you work in (list at the end). When something is not covered here, read the module's own docs
(`h MishkaPay.Checkout` in IEx, or the source under `deps/mishka_pay/lib`) rather than guessing a
field or a function.

## The model in five lines

1. **A provider is a plugin.** `MishkaPay.Providers.Stripe` is a mishka_installer plugin: the host
   supervises it, and every call names it by its id (`"stripe"`). Nothing else names a provider.
2. **Keys come from the host at runtime, per tenant.** The host answers `MishkaPay.Credentials`
   with a plugin, for each provider and tenant (a site, a shop). Never in `config.exs`.
3. **Every call answers a struct or an error.** `{:ok, %MishkaPay.Payment{}}`, or
   `{:error, error}` where `error` is a `MishkaPay.Errors` (Splode) exception. Match on them.
4. **The provider is the source of truth.** Read a payment or subscription again
   (`fetch_payment/3`, `fetch_subscription/3`) instead of trusting a stored copy or a webhook body.
5. **Changes are announced as mishka_installer events**, never through a PubSub of its own. The
   host bridges them to Phoenix.PubSub, LiveView, email, access rights.

## Setup in a host project

```elixir
# mix.exs
{:mishka_pay, "~> 0.0.1"}
# for the Ash layer, also:
{:ash, "~> 3.37"}, {:ash_postgres, "~> 2.15"}, {:ash_oban, "~> 0.10.3"}
```

Supervise the provider and the host's keys plugin (both are plugins):

```elixir
# lib/my_app/application.ex, children
MishkaPay.Providers.Stripe,
MyApp.Pay.Keys
```

```elixir
defmodule MyApp.Pay.Keys do
  use MishkaPay.Credentials

  @impl MishkaPay.Credentials
  def credentials("stripe", tenant) do
    case MyApp.Sites.payment_settings(tenant) do
      %{stripe_secret_key: key} = s when is_binary(key) ->
        %{secret_key: key, webhook_secret: s.stripe_webhook_secret, mode: :test, refunds: :once}

      _no_keys ->
        nil
    end
  end

  def credentials(_provider, _tenant), do: nil
end
```

Keys fields: `secret_key` (required), `publishable_key`, `webhook_secret`, `mode` (`:test`
default, or `:live`), `merchant_of_record` (Stripe Managed Payments, `true`/`false`/absent),
`refunds` (`:once` default, or `:many`), `extra` (a map). Answer `nil` for a tenant without keys.

Mount the webhook endpoint **before** `Plug.Parsers` in the endpoint (it needs the raw body):

```elixir
plug MishkaPay.Webhook, at: "/pay/webhooks"
plug Plug.Parsers, ...
```

Each tenant's webhook URL is `/pay/webhooks/<provider>/<tenant>`, for example
`https://shop.test/pay/webhooks/stripe/site-42`. See `usage-rules/webhooks.md`.

## The calls

| Call | Answers |
|---|---|
| `MishkaPay.checkout(attrs)` | `{:ok, %MishkaPay.Checkout{url: url}}`: redirect the buyer to `url` |
| `MishkaPay.fetch_checkout(provider, checkout_id, tenant)` | the checkout read back, with `:payment_id` or `:subscription_id` once paid |
| `MishkaPay.fetch_payment(provider, payment_id, tenant)` | `%MishkaPay.Payment{}` with status, buyer, card, refunds |
| `MishkaPay.refund(attrs)` | `%MishkaPay.Refund{}` |
| `MishkaPay.fetch_subscription(provider, id, tenant)` | `%MishkaPay.Subscription{}` |
| `MishkaPay.cancel_subscription(provider, id, tenant, at: :period_end \| :now)` | the subscription after |
| `MishkaPay.resume_subscription(provider, id, tenant)` | takes back a cancel set for the period's end |
| `MishkaPay.invoices(provider, subscription_id, tenant)` | `[%MishkaPay.Invoice{}]`, newest first |

A one-time checkout:

```elixir
{:ok, checkout} =
  MishkaPay.checkout(%{
    provider: "stripe",
    tenant: site.id,
    items: [%{name: "Elixir ebook", amount: %{amount: "19.99", currency: "USD"}, quantity: 1,
              tax_code: "txcd_10302000"}],
    success_url: url(~p"/thanks") <> "?session_id={CHECKOUT_SESSION_ID}",
    cancel_url: url(~p"/cart"),
    reference: order.id,
    customer: %{email: user.email}
  })

redirect(conn, external: checkout.url)
```

- **Money** is `%{amount: "19.99", currency: "USD"}` (a string amount, never a float) or an
  `ex_money` `Money`. The amount may have at most the currency's own decimals.
- **`reference`** is the host's own id for the sale (order id). It makes the idempotency key, so the
  same reference never opens two checkouts; it comes back on the payment. Always set it.
- **`tenant`** is passed to every call in a multi-site project. A single-site project may leave it
  `nil` and answer the same keys for every tenant.
- A **subscription** is a checkout with `mode: :subscription`, items with `interval:` and an
  optional `trial_days:`. See `usage-rules/subscriptions.md`.
- A `success_url`/`cancel_url` must be `https`, or `http` on `localhost`.

## Errors

Match the error's struct. Show people plain words, never `inspect(error)`:
`MishkaPay.Ash.message(error)` with the Ash layer (it also drops Ash breadcrumbs), or
`Exception.message(error)` without it.

| Error | Means | Do |
|---|---|---|
| `MishkaPay.Errors.Invalid` | bad input; `errors` has each field | show it on the field |
| `MishkaPay.Errors.Declined` | the card or buyer was declined (`reason`) | ask for another payment method |
| `MishkaPay.Errors.Rejected` | the provider refused the request (`status`, `code`) | log it; often keys or ids |
| `MishkaPay.Errors.Refused` | the host's own checkout gate said no | show its reason |
| `MishkaPay.Errors.Unsupported` | the provider cannot do it (`operation`) | pick another provider or path |
| `MishkaPay.Errors.MissingCredentials` | no keys for that provider and tenant | the site must add keys |
| `MishkaPay.Errors.UnknownProvider` | no such provider installed | supervise the provider |
| `MishkaPay.Errors.Unreachable` | no answer from the provider | retry later; nothing was charged twice |

## Refunds

```elixir
MishkaPay.refund(%{provider: "stripe", tenant: site.id, payment_id: "pi_...",
                   amount: %{amount: "5", currency: "USD"}, reason: :requested_by_customer})
```

- Leave `amount` out for the whole payment. `reason` is `:requested_by_customer`, `:duplicate` or
  `:fraudulent` (Stripe then blocks that card in the account's Radar: use it only for real fraud).
- The tenant's `refunds:` setting decides how often: `:once` (default) refuses a second refund on
  the same payment; `:many` allows part refunds until it is used up, **each with its own
  `reference:`** (required then).

## Real time

Listen to Mishka Pay's events with a mishka_installer plugin and broadcast on your own PubSub:

```elixir
defmodule MyApp.Pay.PaymentFeed do
  use MishkaInstaller.Event.Hook, event: "mishka_pay:payment:changed"

  @impl true
  def call(%{record: record} = state) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "payments", {:payment_changed, record})
    {:reply, state}
  end
end
```

The event names live in `MishkaPay.Events` (`checkout_before/0`, `credentials/0`,
`webhook_received/0`, `event_process/0`, `payment_changed/0`, `subscription_changed/0`,
`providers/0`). A listener answers its state, so return `{:reply, state}` even when it does
nothing. Supervise every listener like any child.

## Rules for an agent writing payment code

- Pass `tenant` through every call in a multi-site project; take keys only from the keys plugin.
- Set `reference` on every checkout and every `:many` refund.
- Read the payment again from the provider before giving access or shipping; a success URL or
  a webhook body alone is not proof of payment.
- Keep amounts as strings or `Money`; let Mishka Pay check currencies and decimals.
- Give access from the payment's or subscription's **status** (`:paid`, `:active`, `:trialing`),
  and take it away on `:refunded`, `:canceled`, `:past_due`/`:unpaid` as the product decides.
- Answer every listener with `{:reply, state}`; mark a failed webhook listener with
  `%{state | failed: "reason"}` so the provider sends the event again.
- Test with `MishkaPay.Test` (`usage-rules/testing.md`); never call a live provider from tests.
- Use test keys (`sk_test_...`) everywhere outside production.

## Sub-rules: load the one for your task

| Sub-rule | Load it when |
|---|---|
| `usage-rules/stripe.md` | anything Stripe: checkout, Managed Payments, ids, test cards, test clocks |
| `usage-rules/subscriptions.md` | plans, trials, cancel and resume, invoices, renewals |
| `usage-rules/webhooks.md` | the webhook endpoint, signatures, tenants, answers, listeners |
| `usage-rules/ash.md` | storing events, payments or subscriptions in Ash resources |
| `usage-rules/testing.md` | tests of code that takes payments |
| `usage-rules/providers.md` | writing a new provider, or a capability for one |
| `usage-rules/paypal.md` | PayPal (coming soon) |

## With the usage_rules package

```elixir
# mix.exs, deps
{:usage_rules, "~> 1.2", only: :dev}

# mix.exs, project/0
usage_rules: [
  file: "CLAUDE.md",
  usage_rules: [{:mishka_pay, sub_rules: ["stripe", "subscriptions", "webhooks", "ash"]}]
]
```

Then `mix usage_rules.sync`. Name only the sub-rules your project uses.

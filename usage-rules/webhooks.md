# Rules for webhooks in Mishka Pay

`MishkaPay.Webhook` is a Plug. Mount it in the endpoint **before** `Plug.Parsers`, since the
signature is checked on the raw body:

```elixir
plug MishkaPay.Webhook, at: "/pay/webhooks"
plug Plug.Parsers, ...
```

- The URL is `/pay/webhooks/<provider>/<tenant>` (or `/pay/webhooks/<provider>` for one set of
  keys). Give each site's URL to the provider's dashboard.
- Mounted with `forward` after the parsers instead, keep the raw body with
  `body_reader: {MishkaPay.Webhook, :read_body, ["/pay/webhooks"]}` in `Plug.Parsers`.
- The tenant's keys answer the `webhook_secret` (Stripe: `whsec_...`; PayPal: the webhook id).

## What it answers

| Status | When | The provider |
|---|---|---|
| 200 | checked and every listener took it | stops sending |
| 400 | bad or old signature (over 5 minutes), no keys or secret for the tenant, unreadable body | sends again, then gives up |
| 404 | no such provider, or one without `:webhook` | sends again |
| 405 | not a POST | - |
| 413 | body over 1 MB | - |
| 500 | a listener failed, raised, exited or took over 15 s | sends again later |

An unknown tenant gets the same 400 as a bad signature, so strangers cannot tell which sites exist.
A refused message is never stored.

## Listeners

A checked event goes to plugins on `mishka_pay:webhook:received` as `%{event: %MishkaPay.Event{},
failed: nil}`. Answer `{:reply, state}`, or `{:reply, %{state | failed: "why"}}` when you could
not take it, so the provider sends it again.

- A provider may send one event twice and in any order: keep what you did by `event.id`, and read
  the object again (`fetch_payment/3` with `event.payment_id`, `fetch_subscription/3` with
  `event.subscription_id`) instead of trusting the event body.
- Do slow work outside the request: the Ash inbox (`usage-rules/ash.md`) stores each event once
  and works it as an Oban job with retries. Prefer it to doing work in the listener.

## Locally

Stripe: `stripe listen --forward-to localhost:4000/pay/webhooks/stripe/<tenant>` and put the
`whsec_...` it prints in the tenant's keys. Telemetry: `[:mishka_pay, :webhook, :stop]` with
`:status` and `:outcome` (`ok`, `mismatch`, `too_old`, `missing_credentials`, `too_large`...).

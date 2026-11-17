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
- Rolling a Stripe secret: Stripe keeps signing with the old one for a while (up to a day). Put
  the new secret in `webhook_secret` and the old one in `webhook_secrets` (a list); a message
  passes when any of them verifies it, each compared in constant time. Drop the old one when the
  window ends. PayPal has no shared secret and ignores `webhook_secrets`.

  ```elixir
  %{secret_key: key, webhook_secret: s.stripe_webhook_secret,
    webhook_secrets: List.wrap(s.stripe_webhook_secret_old)}
  ```

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

## The events that change anything

`MishkaPay.Providers.Stripe.handled_events/0` is the list, each tested; subscribe the Stripe
webhook endpoint to these:

| Stripe events | Updates |
|---|---|
| `checkout.session.completed` | the payment, or the subscription it started |
| `checkout.session.expired`, `.async_payment_succeeded`, `.async_payment_failed` | the payment |
| `payment_intent.succeeded`, `.payment_failed`, `.canceled`, `.processing`, `.requires_action`, `.amount_capturable_updated` | the payment |
| `charge.succeeded`, `.failed`, `.refunded`, `.captured`, `.expired`; `refund.created`, `.updated`, `.failed` | the payment |
| `charge.dispute.created`, `.updated`, `.closed`, `.funds_withdrawn`, `.funds_reinstated` | the dispute and its payment |
| `invoice.paid`, `.payment_failed`, `.finalized`, `.payment_action_required`, `.voided`, `.marked_uncollectible`, `.overdue`, `.upcoming` | the subscription |
| `invoice_payment.paid` | the payment |
| `customer.subscription.created`, `.updated`, `.deleted`, `.paused`, `.resumed`, `.trial_will_end` | the subscription |
| `customer.created`, `.updated`, `.deleted` | the customer |
| `setup_intent.succeeded`, `.setup_failed`; `payment_method.attached`, `.detached`, `.updated`, `.automatically_updated` | the customer it names |
| `entitlements.active_entitlement_summary.updated` | the customer whose entitlements changed (`:customer_id`) |
| `customer.tax_id.created`, `.updated`, `.deleted` | the customer the tax id belongs to |
| `subscription_schedule.created`, `.updated`, `.released`, `.canceled`, `.completed`, `.aborted`, `.expiring` | the subscription it runs (or let go); `:object_id` is the schedule |
| `radar.early_fraud_warning.created`, `.updated` | its payment (synced again); `:object_id` is the warning (`:object_type` `"radar.early_fraud_warning"`), read with `fetch_fraud_warning/3` |
| `review.opened`, `.closed` | its payment (synced again); `:object_id` is the review (`:object_type` `"review"`), read with `fetch_fraud_review/3` |
| `credit_note.created`, `.updated`, `.voided` | nothing kept: `:object_id` is the note (`:object_type` `"credit_note"`), read with `fetch_credit_note/3` |
| `tax_rate.created`, `.updated` | nothing kept: `:object_id` is the rate (`:object_type` `"tax_rate"`), read with `fetch_tax_rate/3` |

Any other event is verified and stored, and changes nothing.

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

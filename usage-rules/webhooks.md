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

## Thin or snapshot events (Stripe)

Stripe sends events two ways; the site picks one with a developer option, per site in its keys
and per call:

| Keys / option | Default | Choices |
|---|---|---|
| `events` | `:thin` (Stripe's recommended format) | `:thin`: a small notification naming the event's object; `:snapshot`: the event with its object as it was, in the pinned API version |
| `webhook_api` (`api:` on a call) | `:v2` | `:v2`: an event destination, `/v2/core/event_destinations`; `:v1`: `/v1/webhook_endpoints`, snapshot only |

- `MishkaPay.Providers.Stripe.WebhookEndpoint.ensure(tenant, url, opts)` (or `mix
  mishka_pay.stripe.webhook_endpoint --url ...`) makes the endpoint of that kind at `url`, or adds
  the events it lacks: thin (`Stripe.thin_events/0`) or snapshot (`Stripe.handled_events/0`).
  `connected_accounts: true` has a platform's destination take its connected accounts' events
  too (`events_from` `@self`, `@accounts`). A new one answers its `secret` once: keep it as the
  site's `webhook_secret`. `check/3` changes nothing; `disable/2`, `enable/2` and `delete/2` take
  its id (`ed_...` for a thin destination; Stripe keeps a snapshot one as `we_...`). Thin events
  on `api: :v1` are `Errors.Invalid` before any request.
- The webhook takes both kinds whatever the setting, each checked the same way (the
  `Stripe-Signature` header and the tenant's secrets). Moving a site from snapshot to thin: make
  the thin destination beside the old endpoint, put its secret in `webhook_secrets`, then
  disable and delete the old one. Both send one change for a while under two event ids.
- A thin event names its object only. Mishka Pay turns it into the same `MishkaPay.Event` a
  snapshot event gives, so listeners and the Ash inbox work it unchanged: an id that sits inside
  the object (a charge's payment, an invoice's subscription, a tax id's customer, a schedule's
  subscription) is read from the object at once, one request made as the event's account; an
  event about a PaymentIntent, subscription, customer, product or another object named by its own
  id needs none. An object deleted since is named by its id alone; a detached payment method by
  the customer the full event's `changes` give. A read Stripe refuses answers 400, so Stripe
  sends the event again. `event.type` is the snapshot name in both modes: a thin
  `v1.invoice.paid` arrives as `invoice.paid`, a thin-only `v1.invoice.overpaid` as
  `invoice.overpaid` (`Stripe.Mapper.event_type/1`), so a listener matches one name; API v2's
  own events keep Stripe's names (`v2.core.account.updated`). `list_events/3` and
  `replay_events/3` take `types:` by either name.
- Thin events add names with no snapshot form: `v1.customer.subscription.active`, `.past_due`,
  `.unpaid`, `.trialing`, `.incomplete` (and the subscription's item, cancel date and payment
  method changes) sync the subscription; `v1.invoice.payment_succeeded`, `.will_be_due`,
  `.overpaid`, line and discount changes the invoice; product and price activation, a used up
  promotion code, schedule phases and entitlements their objects.
  `v1.billing.meter.error_report_triggered` and `.no_meter_found` are usage reports Stripe
  refused after answering: an Event with `:object_type` `"billing.meter"` and the meter as
  `:object_id`, for a host's own listener (the counts are in the full event,
  `MishkaPay.request/1` on `/v2/core/events/<id>`).
- `MishkaPay.list_events/3` and `MishkaPay.replay_events/3` read the site's kind: thin from
  `/v2/core/events` (20 a page, each the Event its webhook gives, with the same reads), snapshot
  from `/v1/events`; `events:` on the call picks the other. Replay the kind the site's webhook
  takes, so the event ids match those the inbox kept.

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
A tenant whose keys name a connected account (`account_id`) gets 400 (`:account`) for an event
about any other account; the platform's own URL takes its connected accounts' events with
`event.account` set (`usage-rules/stripe.md`, Connect).
A refused message is never stored.

## The events that change anything

`MishkaPay.Providers.Stripe.handled_events/0` is the list, each tested; Stripe sends each thin as
`v1.<name>` (`Stripe.thin_events/0`, with the thin-only names above), and its Event carries
`<name>` (`Stripe.event_types/0` is both, by Event type).
`WebhookEndpoint.ensure/3` subscribes the endpoint to them:

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
| `account.updated`, `account.application.deauthorized` | nothing kept: the connected account is `event.account` (`:object_id` is the account, or the platform's application when it left), read with `fetch_connected_account/4` |
| `v2.core.account.*`, `v2.core.account[requirements].updated` and the other `v2.core.account` thin events (thin only) | nothing kept: `:object_id` and `event.account` are the account, read with `fetch_connected_account/4` |
| `transfer.created`, `.updated`, `.reversed` | nothing kept: `:object_id` is the transfer, read with `fetch_transfer/3` |
| `payout.created`, `.updated`, `.paid`, `.failed`, `.canceled`, `.reconciliation_completed` | nothing kept: `:object_id` is the payout (`fetch_payout/3`); a seller's carries `event.account` |
| `application_fee.created`, `.refunded`, `.refund.updated` | nothing kept: `:object_id` is the fee, or its refund (`:object_type` `"fee_refund"`), read with `fetch_application_fee/3` |
| `credit_note.created`, `.updated`, `.voided` | nothing kept: `:object_id` is the note (`:object_type` `"credit_note"`), read with `fetch_credit_note/3` |
| `tax_rate.created`, `.updated` | nothing kept: `:object_id` is the rate (`:object_type` `"tax_rate"`), read with `fetch_tax_rate/3` |

Any other event is verified and stored, and changes nothing; a thin one costs no read.

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

# Production checklist

- **Live keys only in production.** Each site's keys plugin answers `mode: :live` with `sk_live_`
  keys; test clocks and the cleanup task refuse live keys.
- **Webhooks per site.** One Stripe endpoint per site, `https://your-host/pay/webhooks/stripe/<site>`,
  with that site's `webhook_secret`, sending the events of
  `MishkaPay.Providers.Stripe.handled_events/0`. `mix mishka_pay.stripe.webhook_endpoint --url ...
  --tenant <site>` makes it (and shows its secret once), or adds the events it lacks.
- **Check before going live.** `mix mishka_pay.check --tenant <site> --webhook-url ... --domain
  MyApp.Pay` checks the provider, the keys, the webhook secret and endpoint, the Ash listeners
  and the inbox queue (`MishkaPay.Check`), and fails when one does not pass.
- **After an outage.** `mix mishka_pay.replay_events --tenant <site> --since <time>` delivers again
  the events Stripe sent in the meantime (30 days at most); the inbox keeps each once.
- **Stripe moves on.** `mix mishka_pay.stripe.check_version` fails when Stripe has published an
  API version newer than the pin.
- **Give access from the provider's word.** Read the payment or subscription back
  (`fetch_payment/3`, `fetch_subscription/3`), never from a success URL or a webhook body.
- **Managed Payments (merchant of record).** Each price needs a `tax_code`; Stripe then always
  makes an invoice, and refuses a payment link with invoices off. Turn it on or off per site
  (`merchant_of_record`) or per checkout.
- **Stripe Tax.** Turn it on in the Dashboard (origin address, registrations) before
  `automatic_tax` counts anything.
- **Emails.** Receipts and invoice emails are Stripe Dashboard settings (Customer emails).
- **Refunds.** Choose per site: `:once` (default) or `:many`, each `:many` refund with its own
  `reference`.
- **Disputes.** Take back access while a payment is disputed (`mishka_pay:dispute:changed`), and
  answer before `evidence_due_by`.
- **Oban.** The inbox queue `mishka_pay_inbox` must run in production.

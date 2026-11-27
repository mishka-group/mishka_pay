# Rules for PayPal in Mishka Pay

`MishkaPay.Providers.PayPal` (id `"paypal"`) is supported with a smaller set than Stripe's:
`:checkout`, `:refund`, `:subscription`, `:webhook` and `:raw_request`. Checkout, capture, refunds
(once, or many with a reference), subscriptions and verified webhooks work as with Stripe. Anything
else is refused before any request (the list below); `MishkaPay.Provider.capable/2` asks at
runtime.

Read more: [Take payments with PayPal](https://mishka.tools/pay/docs/paypal) and
[Capabilities by provider](https://mishka.tools/pay/docs/capabilities).

- Keys: `publishable_key` is the app's client id, `secret_key` its secret, `webhook_secret` the
  webhook id (`WH-...`), `mode` sandbox (`:test`) or live.
- A checkout is a PayPal Order; the buyer returns to `success_url` with the Order id in `token`
  (`MishkaPay.return_checkout_id/2` reads it, or a subscription's `subscription_id`). A
  `success_url` made for Stripe (`?session_id={CHECKOUT_SESSION_ID}`) is sent without the
  placeholder, so an extension uses one URL for both.
  Read it back with `fetch_checkout("paypal", order_id, tenant)`: an approved Order is captured
  then, once, whoever reads it first. The payment's id is the Order's id, `:amount_captured`
  is what the capture took, `:charge_id` the capture's id and `:fee` PayPal's fee on it
  (`seller_receivable_breakdown.paypal_fee`). PayPal has no balance movements
  (`:balance`), so `:balance_transaction_id` stays `nil`.
- The reference and the checkout's `:owner` travel together in PayPal's one caller field
  (`custom_id`, 127 characters at most; longer is refused before any request), so a PayPal
  payment or subscription comes back with its owner and `belongs_to_user` and `subscribed?` work
  as with Stripe.
- The capture takes PayPal seconds: on the return page, read the checkout off the request path
  (`start_async/3` in a LiveView), never while the page mounts.
- A subscription is a checkout in `mode: :subscription` with one price that has an `:interval`
  (and `:trial_days` for a free trial). The buyer comes back with its id (`I-...`) in
  `subscription_id`, not in `token`: read it with `fetch_checkout("paypal", id, tenant)`, then
  `fetch_subscription/3`. Bills: `list_invoices("paypal", tenant, subscription_id: id)` and
  `upcoming_invoice/3`. Cancel with `at: :now`; PayPal has no cancel at the period's end, so
  that and `resume_subscription/3` are refused.
- Not supported: a subscription with more than one price, listing or searching subscriptions
  (`:subscription_list`), invoice items (`:invoice_item`), credit notes (`:credit_note`), subscription schedules (`:subscription_schedule`), fraud warnings and reviews (`:fraud`), payment and setup intents for a card form of the site's own (`:intent`), tax rates (`:tax_rate`), tax registrations and settings (`:tax_setup`), connected accounts, their links, application fees and a checkout for a seller (`:connect`; keys' `account_id` is ignored), transfers (`:transfer`), payouts, their schedule and the bank they go to (`:payout`, `:payout_schedule`, `:payout_destination`), a customer's bills, one bill by id,
  changing or pausing a subscription, provider price ids, merchant of record, metadata, currencies PayPal
  does not take, decimals in HUF, JPY, TWD, coupons and promotion codes, ending a checkout, and the
  checkout options (`discounts`, `allow_promotion_codes`, `automatic_tax`, `customer_creation`,
  `locale`, `expires_at`, `billing_address`, `tax_id_collection`, `invoice`, a price's
  `tax_behavior` and `tax_rate_ids`), payment links and the catalog: each is refused with
  `Errors.Unsupported`.
- Webhooks are verified by PayPal's own API; they cannot be simulated locally.
  `MishkaPay.Providers.PayPal.WebhookEndpoint.ensure(tenant, url)` makes the site's webhook in
  its PayPal app with `MishkaPay.Providers.PayPal.handled_events/0` (or adds the ones it lacks),
  and answers its id (`WH-...`): keep it as the site's `webhook_secret`. `check/2` changes
  nothing; `delete/2` takes the id; `MishkaPay.Check.run(provider: "paypal", webhook_url: url)`
  checks it. The URL must be `https`. Before PayPal is asked, a message whose
  `paypal-transmission-time` is more than 300 seconds from now (`config :mishka_pay,
  MishkaPay.Providers.PayPal, webhook_tolerance: seconds`) is refused as `BadSignature`
  `:too_old`, and one whose `paypal-cert-url` is not on `api.paypal.com` or
  `api.sandbox.paypal.com` as `:certificate`: both answer 400 and make no request.
- Every event names the Order it is about as `:payment_id`: the Order's own events, a capture's
  (`supplementary_data`), and a refund's or a buyer's dispute's (`CUSTOMER.DISPUTE.CREATED`,
  `UPDATED`, `RESOLVED`), whose capture is read once to find its Order (a read PayPal refuses
  answers 400, so PayPal sends it again).
- A payment is `disputed: true` while a buyer's dispute holds its capture (open, or resolved for
  the buyer; `fetch_payment/3` reads the capture's disputes, one more request for a captured
  Order) and once PayPal reversed the capture (`REVERSED`, a chargeback); a dispute resolved for
  the seller no longer counts. A site's webhook made before this needs `WebhookEndpoint.ensure/2`
  again to hear the dispute events. An approval's webhook alone captures the
  Order through the Ash payment sync, so a buyer who never comes back still pays once.
- `MishkaPay.request/1` calls any PayPal REST path (`"/v2/checkout/orders/<id>"`) with the
  site's OAuth token; a write's body is JSON and its `:reference` makes `PayPal-Request-Id`.
  PayPal has no API version or expand: `options:` with either is `Errors.Invalid` on `:options`.

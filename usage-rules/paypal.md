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
- A checkout is a PayPal Order; the buyer returns to `success_url` with the Order id in `token`.
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
- `MishkaPay.request/1` calls any PayPal REST path (`"/v2/checkout/orders/<id>"`) with the
  site's OAuth token; a write's body is JSON and its `:reference` makes `PayPal-Request-Id`.
  PayPal has no API version or expand: `options:` with either is `Errors.Invalid` on `:options`.

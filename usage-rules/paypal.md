# Rules for PayPal in Mishka Pay (coming soon)

`MishkaPay.Providers.PayPal` (id `"paypal"`) exists with `:checkout`, `:refund` and `:webhook`.
Checkout, capture and refunds (once, or many with a reference) have run against PayPal's sandbox;
webhooks from the sandbox are still to come (mishka-group/mishka_pay#17). Prefer Stripe in
production until then.

- Keys: `publishable_key` is the app's client id, `secret_key` its secret, `webhook_secret` the
  webhook id (`WH-...`), `mode` sandbox (`:test`) or live.
- A checkout is a PayPal Order; the buyer returns to `success_url` with the Order id in `token`.
  Read it back with `fetch_checkout("paypal", order_id, tenant)`: an approved Order is captured
  then, once, whoever reads it first. The payment's id is the Order's id, and `:amount_captured`
  is what the capture took.
- The capture takes PayPal seconds: on the return page, read the checkout off the request path
  (`start_async/3` in a LiveView), never while the page mounts.
- Not supported: subscriptions, provider price ids, merchant of record, metadata, currencies PayPal
  does not take, decimals in HUF, JPY, TWD, coupons and promotion codes, ending a checkout, and the
  checkout options (`discounts`, `allow_promotion_codes`, `automatic_tax`, `customer_creation`,
  `locale`, `expires_at`, `billing_address`, `tax_id_collection`, `invoice`, a price's
  `tax_behavior`), payment links and the catalog: each is refused with
  `Errors.Unsupported`.
- Webhooks are verified by PayPal's own API; they cannot be simulated locally.

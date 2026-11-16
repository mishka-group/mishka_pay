# Rules for Stripe in Mishka Pay

`MishkaPay.Providers.Stripe` (id `"stripe"`) has every capability: `:checkout`, `:refund`,
`:subscription`, `:webhook`. Its API version is pinned (`MishkaPay.Providers.Stripe.version/0`).

## Checkout

- A checkout is a Stripe Checkout Session. The buyer comes back to `success_url` with the session
  id when the URL carries Stripe's placeholder: `url(~p"/thanks") <> "?session_id={CHECKOUT_SESSION_ID}"`.
- On that page, read it back: `MishkaPay.fetch_checkout("stripe", session_id, tenant)`. Its
  `:payment_id` (one-time) or `:subscription_id` (subscription) is set once Stripe took the money.
  Then read the payment or subscription itself before giving access.
- `:amount_total` and `:amount_tax` on the read-back checkout are what Stripe charged, tax
  included.

## Managed Payments (merchant of record)

- With `merchant_of_record: true` (the checkout's own field, else the tenant's keys setting, else
  the Stripe account's default) Stripe sells as the merchant of record and adds tax. Every item
  then needs a `tax_code` (`"txcd_10302000"` digital book, `"txcd_10103001"` SaaS).
- The buyer's total can be higher than the item price (tax). Show "+ tax" next to prices.

## Ids and what is refused before any request

- Ids are checked by prefix: payments `pi_`, checkouts `cs_`, subscriptions `sub_`, customers
  `cus_`, test clocks `clock_`. A wrong kind is an `Errors.Invalid` on the field, and no request is sent.
- Refused as `Errors.Unsupported`: HUF, TWD, ISK, UGX, MGA (Stripe counts them differently from
  ISO 4217). BHD, JOD, KWD, OMR and TND only with a last decimal of 0.
- Metadata: at most 49 keys of 40 characters, values of 500, string keys and values.

## Payments as Mishka Pay reads them

`fetch_payment("stripe", "pi_...", tenant)` reads the PaymentIntent with its charge, the charge's
refunds and the customer in one request, and answers `:status`, `:amount`, `:amount_refunded`,
`:customer_email`, `:customer_name`, `:card_brand`, `:card_last4`, `:receipt_url`,
`:failure_code`, `:failure_message`, `:description`, `:metadata` and `:refunds`.

## Checkout options and discounts

- `expires_at` must be 30 minutes to 24 hours from now; anything else is `Errors.Invalid` before
  any request.
- Which payment methods a checkout offers is set in the Stripe Dashboard: this API version refuses
  `payment_method_types`, so Mishka Pay has no such option.
- `automatic_tax` works with Managed Payments on or off.
- A promotion code points to its coupon through Stripe's `promotion` (type `coupon`); Mishka Pay
  reads it as `:coupon_id`.
- A coupon's own id goes into a URL path: letters, digits, `_` and `-` only.

## Subscription changes

- A preview is `POST /v1/invoices/create_preview`; its id starts with `upcoming_in_` and it is
  never stored. Pass its `proration_date` to the change to bill the same amount.
- In this API version `billing_cycle_anchor` is an object (`billing_cycle_anchor[type]`);
  Mishka Pay sends it so.
- Test a change on a test clock: advance it, preview with the clock's `frozen_time` as
  `proration_date`, change, and compare the new invoice's `amount_due` with the preview's.

## Payment links, invoices and tax

- A payment link's `max_purchases` is Stripe's `restrictions.completed_sessions.limit`; once
  reached, the link turns itself off and shows `inactive_message`.
- `invoice: true` is Stripe's `invoice_creation`: an invoice for a one-time payment. Whether
  Stripe emails receipts and invoices is a Dashboard setting (Customer emails), not code.
- Stripe Tax must be turned on in the Dashboard (origin address, registrations) before
  `automatic_tax` counts anything. A price's `tax_behavior` can be set once on a price that had
  none; otherwise make a new price.

## Catalog and lists

- A product may take the host's own `id` (`"ebook"`): letters, digits, `_` and `-`.
- A Stripe price reads its name from its product (expanded), so a listed price says what it sells.
- A page's `:next` is the last item's id (Stripe's `starting_after`).
- `list_payments/3` reads each PaymentIntent with its charge, refunds and customer, as
  `fetch_payment/3` does.

## Customers and the portal

- The customer's `reference` is kept in its metadata as `mishka_pay_reference` and comes back as
  `:reference`; `:default_payment_method` is the customer's invoice default.
- The portal works without a saved portal configuration in the Dashboard (Stripe's default one);
  pass `configuration: "bpc_..."` to use another.
- Stripe sends `customer.created`, `customer.updated` and `customer.deleted`; the Ash customer
  listener syncs the row on each.
- `list_customers/3` leaves out customers made on a test clock (Stripe's list does); read those by
  id with `fetch_customer/3`.
- A `reference` reused within 24 hours with other details is `Errors.Rejected` with code
  `"idempotency_error"` and a plain message.

## Sandbox

- Test cards: `4242 4242 4242 4242` (Visa), `5555 5555 5555 4444` (Mastercard), `4000 0025 0000
  3155` (3D Secure), `4000 0000 0000 0002` (declined), `4000 0000 0000 9995` (insufficient funds).
  Any future date and CVC. Server-side, the matching tokens are `pm_card_visa`,
  `pm_card_mastercard`, `pm_card_chargeDeclined`...
- A refund with reason `:fraudulent` puts the card in the account's Radar block list; later
  payments with that card are declined (`block_if_in_blocklist`). Use other reasons in tests.
- **Test clocks** show what time does to a subscription: `MishkaPay.Providers.Stripe.TestClock`
  (`create/2`, `fetch/2`, `advance/3`, `list/1`, `delete/2`), test keys only. A clock moves on
  Stripe's servers: read it until `status: :ready`, then read the subscription again.

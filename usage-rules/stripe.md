# Rules for Stripe in Mishka Pay

`MishkaPay.Providers.Stripe` (id `"stripe"`) has every capability: `:checkout`, `:refund`,
`:subscription`, `:webhook`. Its API version is pinned (`MishkaPay.Providers.Stripe.version/0`);
`mix mishka_pay.stripe.check_version` fails when Stripe has published a newer one.

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
  `cus_`, test clocks `clock_`, meters `mtr_`, features `feat_`, payouts `po_`. A wrong kind is an `Errors.Invalid` on the field, and no request is sent.
- ISK, UGX and MGA go in whole units only (Stripe counts them differently from ISO 4217; Mishka
  Pay converts both ways). HUF and TWD charge with two decimals. BHD, JOD, KWD, OMR and TND only
  with a last decimal of 0. Anything else is an `Errors.Invalid` on `:amount` before any request.
- Metadata: at most 48 keys of 40 characters, values of 500, string keys and values.

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

## Disputes

- Dispute ids start with `du_` (older ones `dp_`); both are taken.
- `pm_card_createDispute` (card 4000 0000 0000 0259) pays and opens a dispute a moment later;
  evidence text `"winning_evidence"` wins it and `"losing_evidence"` loses it in test mode.
- `update_dispute/1`'s `evidence` uses Stripe's own field names (`"product_description"`,
  `"customer_email_address"`, `"uncategorized_text"`...); files need their upload id.

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

## Usage billing

- Mishka Pay uses Stripe Billing Meters (`mtr_...`) and meter events. Stripe's docs now point new
  usage-based integrations to Metronome, its main usage billing platform. They say meters stay
  fully supported, and work better with Checkout, Connect and Adaptive Pricing. Mishka Pay has
  no Metronome calls.
- A meter reads the customer from `stripe_customer_id` and the value from `value` in each report
  (Stripe's defaults). A meter is never deleted: `deactivate_meter/3` stops it taking usage or
  new prices.
- A report's `:reference` becomes its `identifier` and its idempotency key. Stripe refuses a
  repeated identifier within at least 24 hours. Without a reference Stripe makes one.
- Stripe takes a report's `:at` within the last 35 days and up to 5 minutes ahead; anything else
  is `Errors.Invalid` on `:at` before any request. A value may have decimals, and a negative one
  corrects usage reported by mistake.
- `usage_summary/6` counts whole minutes: `from` rounds down, `to` rounds up. Stripe counts a
  report a little after it comes in, so a summary read at once may not show it yet.
- A metered price is a recurring price with `meter_id`: Stripe's `recurring[usage_type]=metered`
  and `recurring[meter]`.

## Entitlements

- Features (`feat_...`) attach to products; a customer who subscribes gets active entitlements,
  which `list_entitlements/4` reads. Check access by the entitlement's `:lookup_key`.
- Stripe sends `entitlements.active_entitlement_summary.updated` when a customer's entitlements
  change. The summary has no id, so Mishka Pay names its customer as the event's object
  (`object_type: "customer"`): read `list_entitlements/4` again on it.

## Balances

- `fetch_balance/2` reads the account's payments balance: `available` and `pending`, one money
  per currency, below zero when Stripe's is.
- `list_balance_transactions/3` filters by `payout_id:` (`po_...`, automatic payouts only) and
  `type:` (Stripe's type, such as `"charge"`, `"refund"` or `"payout"`). Each has `:amount`,
  `:fee`, `:net`, `:type`, `:source_id`, `:status` and `:available_at`.
- A customer's balance (`adjust_customer_balance/5`) is Stripe's customer credit balance:
  below zero is credit taken off the next invoices, above zero is a debit added to them. It is
  in the customer's one currency; the first change sets it. Its `:reference` makes the
  idempotency key and is kept in its metadata.

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

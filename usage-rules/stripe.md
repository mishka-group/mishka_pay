# Rules for Stripe in Mishka Pay

`MishkaPay.Providers.Stripe` (id `"stripe"`) has every capability: `:checkout`, `:refund`,
`:subscription`, `:subscription_list`, `:webhook` and the rest. Its API version is pinned (`MishkaPay.Providers.Stripe.version/0`);
`mix mishka_pay.stripe.check_version` fails when Stripe has published a newer one.

## Retries and rate limits

- A read, and a write with its idempotency key, is tried again on a network error and on 408,
  429, 500, 502, 503 and 504. Stripe's `Stripe-Should-Retry` header wins over the status: `true`
  retries even another status (a lock held a moment too long, 409), `false` never retries.
- A 429 is `Errors.Rejected` with `status: 429` and Stripe's `Stripe-Rate-Limited-Reason` as
  `:rate_limit_reason`; the same reason is in `[:mishka_pay, :request, :retry]` and
  `[:mishka_pay, :request, :stop]` telemetry, so a dashboard can count limits by kind.

## Checkout

- A checkout is a Stripe Checkout Session. The buyer comes back to `success_url` with the session
  id when the URL carries Stripe's placeholder: `url(~p"/thanks") <> "?session_id={CHECKOUT_SESSION_ID}"`.
- On that page, read it back: `MishkaPay.fetch_checkout("stripe", session_id, tenant)`. Its
  `:payment_id` (one-time) or `:subscription_id` (subscription) is set once Stripe took the money.
  Then read the payment or subscription itself before giving access.
- `:amount_total` and `:amount_tax` on the read-back checkout are what Stripe charged, tax
  included.

## Embedded checkout and paying later

- `ui_mode: :embedded` is Stripe's `ui_mode=embedded_page`. It sends `return_url` (Stripe refuses
  `success_url` and `cancel_url` there) and answers the session's `client_secret`. The page loads
  Stripe.js and calls `initEmbeddedCheckout` with that secret. Put `{CHECKOUT_SESSION_ID}` in the
  return URL to read the session back there.
- Stripe Managed Payments works with Checkout on a hosted page or an embedded page. Stripe lists
  "payment flows that use Elements with the Checkout Sessions API" and Payment Intents
  integrations as not supported. A Mishka Pay checkout is always a Checkout Session.
- `capture: :manual` is `payment_intent_data[capture_method]=manual`. The PaymentIntent waits in
  `requires_capture`, read as `:authorized`. `capture_payment/4` is
  `POST /v1/payment_intents/:id/capture` with `amount_to_capture` in Stripe's units; Stripe lets
  the rest go. `cancel_payment/3` is `POST /v1/payment_intents/:id/cancel`. Each sends an
  idempotency key, so a retry never captures twice.
- A part to capture is checked against the payment first (one read): another currency, or more
  than it holds, is `Errors.Invalid` on `:amount`. A payment captured in part answers
  `:amount_captured`, and a refund can give back only that part.
- Stripe holds no money where it makes an invoice after payment: `capture: :manual` with
  `invoice: true` or `merchant_of_record: true` is `Errors.Invalid` on `:capture` before any
  request. An account whose default is Managed Payments is refused by Stripe:
  `Errors.Rejected` with code `"capture_invoice"`. Send `merchant_of_record: false` with it.

## Managed Payments (merchant of record)

- With `merchant_of_record: true` (the checkout's own field, else the tenant's keys setting, else
  the Stripe account's default) Stripe sells as the merchant of record and adds tax. Every item
  then needs a `tax_code` (`"txcd_10302000"` digital book, `"txcd_10103001"` SaaS).
- The buyer's total can be higher than the item price (tax). Show "+ tax" next to prices.

## Shipping

- `:shipping_countries` is Stripe's `shipping_address_collection[allowed_countries]`; it works in
  payment and subscription mode. `:shipping_rates` is `shipping_options`: a rate by id (`shr_`)
  or `shipping_rate_data` made with the session, at most 5, in payment mode only.
- Stripe refuses shipping where Managed Payments is on, in the request or as the account's
  default: pass `merchant_of_record: false` with shipping. The refusal is `Errors.Rejected` with
  code `"managed_payments_shipping"`.
- A rate's delivery estimate is in business days. Stripe sets the first rate on an open session
  until the buyer picks another, so `:amount_shipping` and `:shipping_rate_id` are filled at once.
- A shipping rate's amount cannot change once set; make a new rate instead.

## Ids and what is refused before any request

- Ids are checked by prefix: payments `pi_`, checkouts `cs_`, subscriptions `sub_`, customers
  `cus_`, tax ids `txi_`, tax calculations `taxcalc_`, shipping rates `shr_`, test clocks `clock_`, meters `mtr_`, credit notes `cn_`, subscription schedules `sub_sched_`, features `feat_`, payouts `po_`. A wrong kind is an `Errors.Invalid` on the field, and no request is sent.
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
  `"customer_email_address"`, `"uncategorized_text"`...). The file fields (`"receipt"`,
  `"customer_communication"`, `"customer_signature"`, `"service_documentation"`,
  `"shipping_documentation"`, `"duplicate_charge_documentation"`, `"refund_policy"`,
  `"cancellation_policy"`, `"uncategorized_file"`) take only a `file_...` id; anything else is
  `Errors.Invalid` before any request.

## Files

- `upload_file/1` posts to `https://files.stripe.com/v1/files` as `multipart/form-data`, not to
  `api.stripe.com`. `config :mishka_pay, MishkaPay.Providers.Stripe, files_url: ...` points it
  elsewhere; with only `base_url` set (stripe-mock), uploads go there too.
- Dispute evidence is PDF, JPEG or PNG, up to 5 MB, and its first bytes must match its
  `content_type`; anything else is `Errors.Invalid` before any request. Stripe keeps it 9 months.
- Stripe takes all of a dispute's files together up to 4.5 MB (and 19 pages for Mastercard).
- A file id works in one request only: upload again for another dispute.
- `MishkaPay.File`'s `:url` needs the secret key. `file_link/4` makes a public
  `https://files.stripe.com/links/...` address; `expires_at:` must be still to come.

## Invoice items

- An invoice item (`ii_...`) is `POST /v1/invoiceitems`, the same line `create_invoice/1` adds for
  each item of a draft; without `:invoice_id` Stripe keeps it pending and puts it on the
  customer's next invoice, a subscription's renewal too. Its `:reference` makes the idempotency
  key and is kept in its metadata.
- A change cannot move an item to another customer or bill, and an item on a finalized invoice
  cannot change or be deleted (`Errors.Rejected`). A changed `:amount` is in the item's own
  currency. `:amount` reads back as the price of one, `:total` as all of it.
- `list_invoice_items/3` filters by `customer_id:`, `invoice_id:` and `pending: true`.

## Credit notes

- A credit note (`cn_...`) is `POST /v1/credit_notes` on a finalized invoice; a draft cannot
  take one. Its `:reference` makes the idempotency key and is kept in its metadata.
  `preview_credit_note/1` is `GET /v1/credit_notes/preview` with the same fields.
- `:amount` credits the whole bill, `:lines` each line: a line of the bill by its id (`il_...`,
  an `MishkaPay.InvoiceLine`'s `:id`) with a `:quantity` or an `:amount`, or a line of its own
  (`:name`, `:unit_amount`, `:quantity`).
- On an open bill the note lowers what is due (`type: :pre_payment`). On a paid one
  (`:post_payment`) `:refund_amount` + `:credit_amount` + `:out_of_band_amount` must make the
  note's amount; a bill paid by hand has no charge to refund, so use the other two.
- `void_credit_note/3` works only while the note's bill is still open; on a paid bill Stripe
  refuses it (`Errors.Rejected`).
- A note's lines carry no currency: `list_credit_note_lines/4` reads the note first (two
  requests).
- Stripe sends `credit_note.created`, `.updated` and `.voided`; the event's `:object_id` is the
  note.

## Subscription schedules

- A schedule (`sub_sched_...`) is `POST /v1/subscription_schedules`. This API version has no
  phase `iterations`: Mishka Pay sends a phase's `:iterations` and `:interval` as its `duration`.
- `from_subscription` takes nothing else, metadata neither: a schedule made from a subscription
  with a `:reference` or `:metadata` gets them in a second request (`POST
  /v1/subscription_schedules/:id`). The reference makes the idempotency key either way.
- A phase item is a Stripe price (`price_...`); a schedule's first phase starts now unless
  `:start_at` is given. A changed running schedule needs its current phase with its start date;
  the trial a phase had stays only with its `:trial_end_at`.
- A phase that starts with a trial needs no saved card: the subscription is `:trialing`.
- Test what time does with a test clock on the customer (`MishkaPay.Providers.Stripe.TestClock`).

## Listing subscriptions

- `list_subscriptions/3` is `GET /v1/subscriptions` (`customer`, `price`, `status`); without
  `status:` Stripe leaves canceled ones out. Each comes with its customer, but Stripe expands four
  levels at most, so a listed item has its `:product_id` and the price's nickname, not the
  product's name: `fetch_subscription/3` reads one with its names.
- `search_subscriptions/3` is Stripe's search (`GET /v1/subscriptions/search`, `status` and
  `metadata` fields); its index lags up to a minute, and `:next` is Stripe's `next_page`.

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
- `calculate_tax/1` is Stripe Tax without Checkout (`POST /v1/tax/calculations`): a
  `MishkaPay.TaxLine`'s `:amount` is the whole line (unit price times `:quantity`), as Stripe
  takes it. `record_tax/4` is `POST /v1/tax/transactions/create_from_calculation`; its
  reference makes the idempotency key, and Stripe wants it unique across all transactions. A
  calculation can be recorded for 90 days (`:expires_at`).
- An account without Stripe Tax turned on answers `Errors.Rejected` with code
  `"tax_not_set_up"`; an address Stripe cannot place, `"tax_location_invalid"`. An account with
  it on but with no registration where the buyer is counts a tax of zero.
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
- `delete_customer/3` is `DELETE /v1/customers/:id`: for good, and Stripe cancels the customer's
  subscriptions at once. A second delete of the same id is `Errors.Rejected` with code
  `"resource_missing"`; reading it is `"customer_deleted"`.
- The portal works without a saved portal configuration in the Dashboard (Stripe's default one);
  pass `configuration: "bpc_..."` to use another. Another kind of id is `Errors.Invalid` on
  `:configuration` before any request.
- `create_portal_configuration/1` is `POST /v1/billing_portal/configurations`: `:plans` is
  `features.subscription_update.products` (a product, Stripe's id or the host's own, and its
  `price_...` ids), which Stripe answers only expanded; Mishka Pay asks for it on every read.
  A configuration is never deleted: `active: false` turns it off.
- Stripe sends `customer.created`, `customer.updated` and `customer.deleted`, and
  `customer.tax_id.created`, `.updated` and `.deleted` for a customer's tax ids; the event's
  `:customer_id` names the customer, and the Ash customer listener syncs the row on each.
- Tax ids start with `txi_`. Stripe checks EU VAT, GB VAT and AU ABN numbers against the
  government register after they are added: `:verification` is `:pending` first, and
  `customer.tax_id.updated` comes when the check ends. Other kinds get their format checked only.
  In a sandbox, a number of `000000000` (`DE000000000`) verifies, `111111111` does not, and
  `222222222` stays pending.
- `list_customers/3` leaves out customers made on a test clock (Stripe's list does); read those by
  id with `fetch_customer/3`.
- A `reference` reused within 24 hours with other details is `Errors.Rejected` with code
  `"idempotency_error"` and a plain message.

## Saved cards

- A checkout in `mode: :setup` opens a Checkout Session in Stripe's `setup` mode with the
  `currency` given. Without `customer: %{id: ...}` it sets `customer_creation: always`, so Stripe
  makes a customer and the card is kept on it. It turns Managed Payments off for itself, since
  Stripe takes no setup mode with it. The reference goes on the SetupIntent's metadata.
- `fetch_checkout/3` expands the SetupIntent: `:setup_intent_id` (`seti_`), `:payment_method_id`
  (`pm_`) once the buyer is done, and the customer's id under `:customer`.
- `list_payment_methods/3` reads `GET /v1/customers/:id/payment_methods`; `customer_id:` is
  required.
- `set_default_payment_method/4` sets the customer's `invoice_settings.default_payment_method`,
  which invoices and subscriptions charge.
- `detach_payment_method/3` is for good: Stripe never attaches that payment method again.
- Payment method ids are checked by prefix: `pm_`, or `card_` for a card saved before them.
- `setup_intent.*` and `payment_method.*` events are about the customer they name (a detached
  payment method names it in `previous_attributes`), so the Ash customer row syncs on each.

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
  (the event's `:customer_id`): read `list_entitlements/4` again on it.

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

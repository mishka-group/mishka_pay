# Rules for Stripe in Mishka Pay

`MishkaPay.Providers.Stripe` (id `"stripe"`) has every capability: `:checkout`, `:refund`,
`:subscription`, `:subscription_list`, `:webhook` and the rest. Its API version is pinned (`MishkaPay.Providers.Stripe.version/0`);
`mix mishka_pay.stripe.check_version` fails when Stripe has published a newer one.

## Raw calls

- `MishkaPay.request/1` calls any `api.stripe.com` path (`"/v1/tax/settings"`) with the
  tenant's key and answers Stripe's JSON as a map. `params:` nest as Stripe's form encoding
  takes them (`%{"metadata" => %{"a" => "b"}}`).
- `options: %{api_version: "2025-03-31.basil", expand: ["customer"]}` sends that
  `Stripe-Version` and `expand[]` for this call only; typed calls always use the pinned version.
- A write's `:reference` with its method and path makes the idempotency key; without one, a
  write gets a fresh key that its retries reuse.

## Connect: a platform and its sites

- A platform (Mishka Cloud, a marketplace) keeps one Stripe secret key and gives each site its
  own connected account (`acct_...`). The site's keys answer the platform's `secret_key` with
  the site's `account_id`; every Stripe request for that tenant then carries
  `Stripe-Account: acct_...`, so its payments, customers and refunds live on the site's account.
  Keys without `account_id` are the platform itself.
- The header comes only from the keys. No call, `RequestOptions` or `MishkaPay.request/1` can
  set it: a raw call has no header field. An `account_id` that is not `acct_` and plain is
  `Errors.Invalid` on `:account_id` before any request.
- Webhooks: a tenant with `account_id` takes only events that name that account (Stripe's
  top-level `account`); an event of the platform's own account or of another connected account
  is refused with 400 (`BadSignature`, reason `:account`). Mishka Pay never routes an event to
  another tenant: it keeps no map from account to site, and a message checked with one tenant's
  secret must never act on another's data. A platform subscribes **one** Connect endpoint
  ("Events from: Connected accounts") to its own tenant's URL (keys without `account_id`); each
  event there names its `:account`, and the host's listener finds the site by it. Never point a
  Connect endpoint at a site's URL when the platform has more than one connected account: it
  receives every account's events, refuses the others, and Stripe retries them until it turns
  the endpoint off.
- `create_connected_account/1` is `POST /v1/accounts` with the platform's keys. Stripe's `type`
  is deprecated on this API version: `:express` is sent as `controller` (Express dashboard, the
  platform pays fees and answers for losses), `:standard` as a full dashboard, `:custom` as no
  dashboard with the platform collecting requirements. Its `:reference` makes the idempotency key
  and is kept in metadata. A platform that has not signed up for Connect in the Dashboard is
  `Errors.Rejected` with code `"connect_not_set_up"`.
- `account_link/1` is `POST /v1/account_links` (`account_onboarding` or `account_update`); its
  URL runs out in minutes and works once, so make it per click and redirect at once. Both pages
  are `https` (or `http` on `localhost`). Coming back to `return_url` does not mean the account
  is ready: read it (`:details_submitted`, `:charges_enabled`, `:requirements_due`). `login_link/3`
  works only for an Express account that finished onboarding.
- `reject_connected_account/4` is for good; Stripe's reasons on this API version are `credit`,
  `fraud_no_intent_to_fulfill`, `fraud_other`, `fraud_payment_method_casher`,
  `fraud_payment_method_tester`, `terms_of_service` and `other` (the default). Account ids start
  with `acct_`.
- Stripe sends `account.updated` (onboarding moved on, a capability turned on or off) and
  `account.application.deauthorized` (a Standard account left the platform) to the platform's
  Connect endpoint; `event.account` names the account.

## Connect: money between accounts

- Two ways to sell for a seller. **Destination charge**: the platform's keys (no `account_id`)
  and a checkout with `destination:` (and usually `on_behalf_of:`): the payment lives on the
  platform and Stripe moves it on (`payment_intent_data[transfer_data][destination]`). **Direct
  charge**: the site's keys name its `account_id`, so the checkout is made on the seller's own
  account. Either way `application_fee:` is `application_fee_amount` (one-time) and
  `application_fee_percent:` is `subscription_data[application_fee_percent]`; both go to the
  platform. Mishka Pay makes PaymentIntents only through a checkout, so these are the only
  places it sends them.
- `create_transfer/1` is `POST /v1/transfers` from the platform's balance: `:reference` is
  required, makes the idempotency key and is kept in metadata; `:source_charge_id` (`ch_...`)
  is `source_transaction`, so the transfer waits for that sale's money. A destination that is
  not the platform's is `Errors.Rejected` with code `"resource_missing"` (param `destination`).
- `reverse_transfer/4` is `POST /v1/transfers/:id/reversals` with `expand[]=transfer`, so one
  request answers the transfer after (`:amount_reversed`, `:reversed`). `refund_application_fee/4`
  is `POST /v1/application_fees/:id/refunds` with `expand[]=fee`, the same way. Each with a
  `:reference` is made once; the same reference on another transfer or fee is another call.
- `list_payouts/3` (`status:` `:pending`, `:in_transit`, `:paid`, `:failed`, `:canceled`),
  `fetch_payout/3` and `cancel_payout/3` act on the account the keys act for: the platform, or
  with a site's `account_id` the seller's. Only a `:pending` payout can be canceled.
- Ids: transfers `tr_`, payouts `po_`, application fees `fee_`, accounts `acct_`; a wrong kind is
  `Errors.Invalid` before any request.
- Stripe sends `transfer.created`, `.updated`, `.reversed`; `payout.created`, `.updated`,
  `.paid`, `.failed`, `.canceled`, `.reconciliation_completed`; `application_fee.created`,
  `.refunded`, `.refund.updated`. A seller's payout events reach the platform's Connect endpoint
  with `event.account` set.

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

## Stripe Elements: payment and setup intents

- `create_payment_intent/1` is `POST /v1/payment_intents`, `create_setup_intent/1`
  `POST /v1/setup_intents`, both with `automatic_payment_methods[enabled]` (the Dashboard's
  payment methods; `automatic_payment_methods: false` is cards only). Their `:reference` makes
  the idempotency key and is kept in the metadata (`:owner` too), so a paid intent reads back
  through `fetch_payment/3` with its reference and owner, and its `payment_intent.*` webhooks sync
  the Ash payment row like a checkout's.
- The page loads `https://js.stripe.com/<version>/stripe.js`, makes
  `stripe.elements({clientSecret})`, mounts `elements.create("payment")`, and calls
  `stripe.confirmPayment({elements, redirect: "if_required", confirmParams: {return_url}})` (or
  `confirmSetup`). The publishable key is the tenant's `publishable_key`.
- `confirm_payment_intent/4` and `confirm_setup_intent/4` confirm on the server with a saved
  payment method (`pm_...`); with the Dashboard's payment methods on, Stripe wants a
  `return_url:` too. In tests use Stripe's test payment methods (`pm_card_visa`,
  `pm_card_mastercard`); never send a card number.
- `capture: :manual` holds the money: `:requires_capture` after the confirm, then
  `capture_payment/4`, or `cancel_payment_intent/3` to let it go.
- `update_payment_intent/1` sends only what it names; a changed `:amount` sends its currency
  too. A paid or canceled intent cannot change (`Errors.Rejected`).
- A declined card on a server confirm is `Errors.Declined` with the bank's reason; read in the
  browser, the intent's `:failure_code` and `:failure_message` say why the last try failed.
- Stripe lists Payment Intents integrations as not supported by Managed Payments: an intent is
  never sold with Stripe as the merchant of record.

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

- Ids are checked by prefix: payments `pi_`, setup intents `seti_`, checkouts `cs_`, subscriptions `sub_`, customers
  `cus_`, tax ids `txi_`, tax calculations `taxcalc_`, tax rates `txr_`, tax registrations `taxreg_`, shipping rates `shr_`, test clocks `clock_`, meters `mtr_`, credit notes `cn_`, early fraud warnings `issfr_`, reviews `prv_`, subscription schedules `sub_sched_`, features `feat_`, payouts `po_`. A wrong kind is an `Errors.Invalid` on the field, and no request is sent.
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

## Radar: early fraud warnings and reviews

- An early fraud warning (`issfr_...`) is `GET /v1/radar/early_fraud_warnings`, filtered by
  `payment_id:` (`pi_`) or `charge_id:`. Stripe makes one when a card issuer reports fraud,
  never on request; in a sandbox the test card `4000 0000 0000 5423`, paid on a checkout page,
  makes one a moment later (the API takes no card number, and has no token for it).
- `:actionable` is true while the payment is neither refunded nor disputed: a full refund then
  usually stops the dispute and its fee.
- `list_fraud_reviews/3` is `GET /v1/reviews`, which lists only open reviews (`prv_...`).
  Radar opens one only where the account has a review rule (Radar for Fraud Teams);
  `approve_fraud_review/3` is `POST /v1/reviews/:id/approve`. Refunding the payment closes a
  review as refunded.
- Stripe sends `radar.early_fraud_warning.created`, `.updated`, `review.opened` and
  `review.closed`; each names its payment (the event's `:payment_id`), which the Ash payment
  listener reads again, and the warning or review as `:object_id`.

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
- Stripe Tax must be turned on (head office, registrations) before `automatic_tax` counts
  anything: `update_tax_settings/1` sets the head office and defaults, `create_tax_registration/1`
  the registrations; `fetch_tax_settings/2` says `:pending` with the `:missing_fields` until then. A price's `tax_behavior` can be set once on a price that had
  none; otherwise make a new price.

## Tax rates, registrations and settings

- A tax rate (`txr_...`) is `POST /v1/tax_rates`; its `:reference` makes the idempotency key and
  is kept in its metadata. Its percentage and `inclusive` never change, and it is never deleted:
  `update_tax_rate/1` with `active: false` archives it, and the lines that have it keep it.
- A checkout's line sends its `:tax_rate_ids` as `line_items[][tax_rates]`, an invoice item as
  `tax_rates`, a draft bill as `default_tax_rates` (for every line without its own), a schedule's
  phase item as `tax_rates`. Stripe takes none on a catalog price or a payment link, and none
  with automatic tax (the checkout's, or the site's `automatic_tax: true`): each is
  `Errors.Invalid` on `:tax_rate_ids` before any request.
- A tax registration (`taxreg_...`) is `POST /v1/tax/registrations`: the `:type` and `:state`
  go under `country_options[<country>]` (Canada's provincial one as
  `province_standard[province]`); a US registration and Canada's `"province_standard"` need
  `:state`, refused before any request without it, and any other registration refuses one.
  A `"standard"` registration may say its `:place_of_supply_scheme`, sent as
  `standard[place_of_supply_scheme]`: in an EU country `:standard`, `:small_seller` or
  `:inbound_goods`; in the other countries whose standard registration has one (GB, NO, CH,
  AU, JP, IS and others) `:standard` or `:inbound_goods`.
  `MishkaPay.Providers.Stripe.place_of_supply_schemes/2` gives the list for a country and kind;
  any other scheme, kind or country is `Errors.Invalid` before any request.
  `expire_tax_registration/4` sets `expires_at` (`now` unless `at:`); Stripe never deletes one.
  A second registration of the same kind in a country is `Errors.Rejected`.
- `fetch_tax_settings/2` and `update_tax_settings/1` are `GET` and `POST /v1/tax/settings`:
  `:head_office` is `head_office[address]`, `:tax_code` and `:tax_behavior` are `defaults`.
- Stripe sends `tax_rate.created` and `.updated`; the event's `:object_id` is the rate.

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
- `cancel_usage/1` is a meter event adjustment (`POST /v1/billing/meter_event_adjustments`,
  `type: cancel`) of the report's identifier (the `MishkaPay.Usage`'s `:id`), within 24 hours of
  the report; its idempotency key comes from the event name and identifier, so it cancels once.
  Its `:status` is `:pending` until Stripe has taken the report out. Later, report the value
  again below zero.
- `update_meter/1` changes the display name only (`POST /v1/billing/meters/:id`);
  `reactivate_meter/3` turns a deactivated meter on again.
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

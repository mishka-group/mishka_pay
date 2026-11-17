# Rules for working with Mishka Pay

Mishka Pay (`:mishka_pay`) takes payments in Elixir projects: checkouts, payments, refunds,
subscriptions and verified webhooks, the same way for every provider. Stripe is the full provider;
PayPal's adapter exists and waits for its sandbox run. An optional Ash layer (the
`MishkaPay.Ash.Resource` extension) stores events, payments, subscriptions, customers and disputes
in the host's own resources.

Read this file before writing any code that touches payments. Then load the sub-rule for the area
you work in (list at the end). When something is not covered here, read the module's own docs
(`h MishkaPay.Checkout` in IEx, or the source under `deps/mishka_pay/lib`) rather than guessing a
field or a function.

## The model in five lines

1. **A provider is a plugin.** `MishkaPay.Providers.Stripe` is a mishka_installer plugin: the host
   supervises it, and every call names it by its id (`"stripe"`). Nothing else names a provider.
2. **Keys come from the host at runtime, per tenant.** The host answers `MishkaPay.Credentials`
   with a plugin, for each provider and tenant (a site, a shop). Never in `config.exs`.
3. **Every call answers a struct or an error.** `{:ok, %MishkaPay.Payment{}}`, or
   `{:error, error}` where `error` is a `MishkaPay.Errors` (Splode) exception. Match on them.
4. **The provider is the source of truth.** Read a payment or subscription again
   (`fetch_payment/3`, `fetch_subscription/3`) instead of trusting a stored copy or a webhook body.
5. **Changes are announced as mishka_installer events**, never through a PubSub of its own. The
   host bridges them to Phoenix.PubSub, LiveView, email, access rights.

## Setup in a host project

The installer does all of this in a Phoenix project, and never twice:

```bash
mix igniter.install mishka_pay            # provider, keys plugin, webhook plug, test config
mix igniter.install mishka_pay --ash --pubsub   # plus the Ash resources and the PubSub plugin
```

By hand:

```elixir
# mix.exs
{:mishka_pay, "~> 0.0.1"}
# for the Ash layer, also:
{:ash, "~> 3.37"}, {:ash_postgres, "~> 2.15"}, {:ash_oban, "~> 0.10.3"}
```

Mishka Pay's application starts the providers itself (`config :mishka_pay, providers: [...]`,
all by default). Outside Mishka CMS, supervise mishka_installer's registry first (it starts only
what nothing else started), then the host's keys plugin:

```elixir
# lib/my_app/application.ex, children
MishkaPay.Registry,
MyApp.Pay.Keys
```

```elixir
defmodule MyApp.Pay.Keys do
  use MishkaPay.Credentials

  @impl MishkaPay.Credentials
  def credentials("stripe", tenant) do
    case MyApp.Sites.payment_settings(tenant) do
      %{stripe_secret_key: key} = s when is_binary(key) ->
        %{secret_key: key, webhook_secret: s.stripe_webhook_secret, mode: :test, refunds: :once}

      _no_keys ->
        nil
    end
  end

  def credentials(_provider, _tenant), do: nil
end
```

Keys fields: `secret_key` (required), `publishable_key`, `webhook_secret`, `webhook_secrets`
(older secrets still accepted while a rolled one runs out, see `usage-rules/webhooks.md`), `mode` (`:test`
default, or `:live`), `merchant_of_record` (Stripe Managed Payments, `true`/`false`/absent),
`refunds` (`:once` default, or `:many`), `automatic_tax` (`true` counts the tax of every checkout
and payment link of this site with Stripe Tax; a checkout's own choice wins), `account_id` (the
connected account the site acts for on a Stripe Connect platform: `acct_...`, sent as
`Stripe-Account` on every request; see `usage-rules/stripe.md`), `extra` (a map). Answer `nil` for a tenant without keys.

Mount the webhook endpoint **before** `Plug.Parsers` in the endpoint (it needs the raw body):

```elixir
plug MishkaPay.Webhook, at: "/pay/webhooks"
plug Plug.Parsers, ...
```

Each tenant's webhook URL is `/pay/webhooks/<provider>/<tenant>`, for example
`https://shop.test/pay/webhooks/stripe/site-42`. See `usage-rules/webhooks.md`.

## The calls

| Call | Answers |
|---|---|
| `MishkaPay.checkout(attrs)` | `{:ok, %MishkaPay.Checkout{url: url}}`: redirect the buyer to `url` |
| `MishkaPay.fetch_checkout(provider, checkout_id, tenant)` | the checkout read back, with `:payment_id` or `:subscription_id` once paid |
| `MishkaPay.fetch_payment(provider, payment_id, tenant)` | `%MishkaPay.Payment{}` with status, buyer, card, refunds |
| `MishkaPay.checkout(%{ui_mode: :embedded, return_url: url, ...})` | `%MishkaPay.Checkout{client_secret: secret}`: the provider's form inside the site's page |
| `MishkaPay.capture_payment(provider, payment_id, tenant, amount: money)`, `cancel_payment/3` | the `%MishkaPay.Payment{}` after: a held (`:authorized`) payment taken, all or part, or let go |
| `MishkaPay.refund(attrs)` | `%MishkaPay.Refund{}` |
| `MishkaPay.fetch_refund(provider, refund_id, tenant)`, `list_refunds(provider, tenant, payment_id: id)` | `%MishkaPay.Refund{}` read again; a `MishkaPay.Page` of them |
| `MishkaPay.fetch_subscription(provider, id, tenant)` | `%MishkaPay.Subscription{}` |
| `MishkaPay.list_subscriptions(provider, tenant, customer_id: id, status: :all)` (or `price_id:`), `search_subscriptions(provider, tenant, reference: r, metadata: %{...})` | a `MishkaPay.Page` of `%MishkaPay.Subscription{}`; the provider needs `:subscription_list` |
| `MishkaPay.cancel_subscription(provider, id, tenant, at: :period_end \| :now)` | the subscription after |
| `MishkaPay.create_subscription_schedule(attrs)` (`MishkaPay.SubscriptionSchedule`: `:subscription_id`, or `:customer_id` and `:phases` of `MishkaPay.SubscriptionPhase`; `:end_behavior`, `:reference`), `fetch_subscription_schedule/3`, `list_subscription_schedules(p, tenant, customer_id: id)`, `update_subscription_schedule/1`, `release_subscription_schedule/3`, `cancel_subscription_schedule/4` | `%MishkaPay.SubscriptionSchedule{}`: a subscription's changes planned ahead in phases; the provider needs `:subscription_schedule` |
| `MishkaPay.resume_subscription(provider, id, tenant)` | takes back a cancel set for the period's end |
| `MishkaPay.change_subscription(attrs)`, `preview_subscription_change/1` | a new plan or quantity, with proration; the preview is the `%MishkaPay.Invoice{}` it would bill |
| `MishkaPay.pause_collection(provider, id, tenant, behavior: ...)`, `resume_collection/3` | stops or starts charging without cancelling |
| `MishkaPay.fetch_invoice(provider, invoice_id, tenant)` | `%MishkaPay.Invoice{}` with its `:lines` |
| `MishkaPay.create_invoice(attrs)` (`MishkaPay.InvoiceDraft`) | a draft `%MishkaPay.Invoice{}` for a customer, with its items |
| `MishkaPay.finalize_invoice/3`, `send_invoice/3`, `pay_invoice(p, id, tenant, out_of_band: true)`, `void_invoice/3`, `mark_invoice_uncollectible/3`, `delete_invoice/3` | open, email, settle or end a one-off bill |
| `MishkaPay.create_invoice_item(attrs)` (`MishkaPay.InvoiceItem`: `:customer_id`, `:price_id` or `:name` and `:amount`, `:quantity`, `:invoice_id`, `:reference`), `update_invoice_item/1`, `delete_invoice_item/3`, `list_invoice_items(p, tenant, customer_id: id, pending: true)` | `%MishkaPay.InvoiceItem{}`: a charge that waits for the customer's next bill (or goes on a draft one); the provider needs `:invoice_item` |
| `MishkaPay.create_credit_note(attrs)` (`MishkaPay.CreditNote`: `:invoice_id`, `:amount` or `:lines`, `:reason`, `:refund_amount`, `:credit_amount`, `:out_of_band_amount`, `:memo`, `:reference`), `preview_credit_note/1`, `fetch_credit_note/3`, `void_credit_note/3`, `list_credit_notes(p, tenant, invoice_id: id)`, `list_credit_note_lines(p, note_id, tenant)` | `%MishkaPay.CreditNote{}`: part or all of a finalized bill taken back, the tax-correct way; the provider needs `:credit_note` |
| `MishkaPay.fetch_dispute/3`, `list_disputes/3`, `update_dispute(attrs)`, `accept_dispute/3` | `%MishkaPay.Dispute{}`: a chargeback, answered with evidence or accepted |
| `MishkaPay.list_fraud_warnings(provider, tenant, payment_id: id)`, `fetch_fraud_warning/3` | `%MishkaPay.FraudWarning{}`: a card issuer's early warning of fraud; `:actionable` means a full refund can still head off the dispute; the provider needs `:fraud` |
| `MishkaPay.list_fraud_reviews(provider, tenant)`, `fetch_fraud_review/3`, `approve_fraud_review/3` | `%MishkaPay.FraudReview{}`: a payment the fraud rules hold; approve it to let it through, or refund it |
| `MishkaPay.upload_file(%{provider:, tenant:, purpose: :dispute_evidence, filename:, content_type:, content:})` | `%MishkaPay.File{}`; its `:id` goes in a dispute's file evidence (`"receipt"`, `"uncategorized_file"`...) |
| `MishkaPay.fetch_file(provider, file_id, tenant)`, `file_link(provider, file_id, tenant, expires_at: dt)` | the file read again; a `%MishkaPay.FileLink{}` whose `:url` a page can show |
| `MishkaPay.list_invoices(provider, tenant, subscription_id: id)` (or `customer_id:`) | a `MishkaPay.Page` of `%MishkaPay.Invoice{}` |
| `MishkaPay.list_payments(provider, tenant, customer_id: id)` | a `MishkaPay.Page` of `%MishkaPay.Payment{}` |
| `MishkaPay.create_customer(attrs)` | `%MishkaPay.Customer{}` made at the provider |
| `MishkaPay.update_customer(attrs)` | the customer after (`attrs` has `:provider` and `:id`) |
| `MishkaPay.fetch_customer(provider, customer_id, tenant)` | `%MishkaPay.Customer{}` |
| `MishkaPay.delete_customer(provider, customer_id, tenant)` | `:ok`: the customer is gone at the provider for good (an erase request); its saved cards and running subscriptions end with it |
| `MishkaPay.list_customers(provider, tenant, email: email, limit: 10)` | a `MishkaPay.Page` of `%MishkaPay.Customer{}` |
| `MishkaPay.checkout(%{mode: :setup, currency: "usd", customer: %{id: id}, ...})` | a page that saves a card without a charge; read back, `:setup_intent_id` and `:payment_method_id` |
| `MishkaPay.list_payment_methods(provider, tenant, customer_id: id)`, `fetch_payment_method/3` | a `MishkaPay.Page` of `%MishkaPay.PaymentMethod{}` (type, card brand, last4, expiry); one read again |
| `MishkaPay.set_default_payment_method(provider, customer_id, payment_method_id, tenant)` | the `%MishkaPay.Customer{}` after, with its `:default_payment_method` |
| `MishkaPay.detach_payment_method(provider, payment_method_id, tenant)` | the `%MishkaPay.PaymentMethod{}` taken off its customer for good |
| `MishkaPay.create_tax_id(provider, customer_id, %{type: "eu_vat", value: "DE123456789"}, tenant)`, `list_tax_ids/4`, `delete_tax_id/4` | `%MishkaPay.TaxId{}`: a business buyer's VAT or other tax id, with its `:verification` |
| `MishkaPay.calculate_tax(attrs)` (`MishkaPay.TaxCalculation`: `:items` of `MishkaPay.TaxLine`, `:address` or `:customer_id`, `:shipping`) | `%MishkaPay.TaxCalculation{}`: the tax on a sale outside the checkout, with `:amount_total` to charge |
| `MishkaPay.record_tax(provider, calculation_id, reference, tenant)` | `%MishkaPay.TaxTransaction{}`: the paid sale in the provider's tax reports |
| `MishkaPay.create_shipping_rate(attrs)`, `list_shipping_rates(provider, tenant, active: true)` | `%MishkaPay.ShippingRate{}`: a way to ship and its price, offered by id on checkouts |
| `MishkaPay.list_events(provider, tenant, since: dt, types: [...])` | a `MishkaPay.Page` of `%MishkaPay.Event{}` |
| `MishkaPay.request(%{provider:, tenant:, method: :get, path: "/v1/...", params:, reference:, options: %{api_version:, expand: [...]}})` (`MishkaPay.RawRequest`) | `{:ok, map}`: the provider's own answer, for what has no typed call yet; the provider needs `:raw_request` |
| `MishkaPay.replay_events(provider, tenant, since: dt)` | `%{delivered: n, failed: [{id, reason}]}`: missed events handed to the listeners again |
| `MishkaPay.Check.run(tenant: t, webhook_url: url, domain: MyApp.Pay)` | `[{check, :ok \| {:error, reason}}]`: the site's setup |
| `MishkaPay.portal_session(attrs)` | `%MishkaPay.PortalSession{url: url}`: redirect the buyer there |
| `MishkaPay.create_portal_configuration(attrs)` (`MishkaPay.PortalConfiguration`), `update_portal_configuration/1`, `fetch_portal_configuration/3`, `list_portal_configurations(p, tenant, active: true)` | `%MishkaPay.PortalConfiguration{}`: what buyers may do in the portal; a session names it with `configuration: id` |
| `MishkaPay.expire_checkout(provider, checkout_id, tenant)` | the checkout, `status: :expired`: it can no longer be paid |
| `MishkaPay.create_coupon(attrs)`, `fetch_coupon/3`, `list_coupons/3`, `delete_coupon/3` | `%MishkaPay.Coupon{}` |
| `MishkaPay.create_promotion_code(attrs)`, `fetch_promotion_code/3`, `list_promotion_codes/3`, `update_promotion_code/1` | `%MishkaPay.PromotionCode{}` |
| `MishkaPay.create_product(attrs)`, `fetch_product/3`, `update_product/1`, `archive_product/3`, `list_products/3` | `%MishkaPay.Product{}` |
| `MishkaPay.create_price(attrs)`, `fetch_price/3`, `archive_price/3`, `list_prices/3` | `%MishkaPay.Price{}` |
| `MishkaPay.create_payment_link(attrs)`, `fetch_payment_link/3`, `update_payment_link/1`, `list_payment_links/3` | `%MishkaPay.PaymentLink{url: url}` |
| `MishkaPay.create_meter(attrs)` (`MishkaPay.Meter`), `fetch_meter/3`, `update_meter(%{provider:, id:, name:})`, `list_meters(provider, tenant, status: :active)`, `deactivate_meter/3`, `reactivate_meter/3` | `%MishkaPay.Meter{}` that counts usage; a provider never deletes one, and only its name changes |
| `MishkaPay.create_price(%{..., interval: :month, meter_id: id})` | a `%MishkaPay.Price{}` billed by the usage its meter counted |
| `MishkaPay.report_usage(attrs)` (`MishkaPay.Usage`: `:event_name`, `:customer_id`, `:value`, `:at`, `:reference`) | `%MishkaPay.Usage{id: id}`; the same reference never counts twice |
| `MishkaPay.cancel_usage(%{provider:, tenant:, event_name:, usage_id: usage.id})` (`MishkaPay.UsageCancellation`) | `%MishkaPay.UsageCancellation{status: :pending \| :complete}`: a report sent by mistake taken out of the count, once |
| `MishkaPay.usage_summary(provider, meter_id, customer_id, from, to, tenant)` | `%MishkaPay.UsageSummary{value: n}`: what the meter counted in the window |
| `MishkaPay.create_feature(attrs)` (`MishkaPay.Feature`), `attach_feature(provider, product_id, feature_id, tenant)` | `%MishkaPay.Feature{}`; a buyer of the product is entitled to it |
| `MishkaPay.list_entitlements(provider, customer_id, tenant)` | a `MishkaPay.Page` of `%MishkaPay.Entitlement{lookup_key: key}`: what the customer may use now |
| `MishkaPay.fetch_balance(provider, tenant)` | `%MishkaPay.Balance{available: [money], pending: [money]}`, one money per currency |
| `MishkaPay.list_balance_transactions(provider, tenant, payout_id: id, type: "charge")` | a `MishkaPay.Page` of `%MishkaPay.BalanceTransaction{}` (amount, fee, net, type, source) |
| `MishkaPay.adjust_customer_balance(provider, customer_id, money, tenant, description: d, reference: r)`, `list_customer_balance/4` | `%MishkaPay.CustomerBalanceTransaction{}`: below zero is store credit |

Every `list_*` answers one `MishkaPay.Page` (`:items`, `:has_more`, `:next`) and takes `limit:`
(1 to 100, 10 by default) and `after:` (a page's `:next`). `MishkaPay.Page.stream/1` reads every
page lazily, one request a page:

```elixir
(&MishkaPay.list_payments("stripe", site.id, &1))
|> MishkaPay.Page.stream()
|> Enum.take(500)
```

A one-time checkout:

```elixir
{:ok, checkout} =
  MishkaPay.checkout(%{
    provider: "stripe",
    tenant: site.id,
    items: [%{name: "Elixir ebook", amount: %{amount: "19.99", currency: "USD"}, quantity: 1,
              tax_code: "txcd_10302000"}],
    success_url: url(~p"/thanks") <> "?session_id={CHECKOUT_SESSION_ID}",
    cancel_url: url(~p"/cart"),
    reference: order.id,
    customer: %{email: user.email}
  })

redirect(conn, external: checkout.url)
```

- **Money** is `%{amount: "19.99", currency: "USD"}` (a string amount, never a float) or an
  `ex_money` `Money`. The amount may have at most the currency's own decimals.
- **`reference`** is the host's own id for the sale (order id). It makes the idempotency key, so the
  same reference never opens two checkouts; it comes back on the payment. Always set it.
- **`tenant`** is passed to every call in a multi-site project. A single-site project may leave it
  `nil` and answer the same keys for every tenant.
- A **subscription** is a checkout with `mode: :subscription`, items with `interval:` and an
  optional `trial_days:`. See `usage-rules/subscriptions.md`.
- A **saved card** is a checkout with `mode: :setup` and a `currency:`, without items. It needs a
  provider with `:payment_method`. Name the customer with `customer: %{id: id}`, or the provider
  makes one. Options of a sale (discounts, tax, trial, invoice) are refused in setup mode.
- A `success_url`/`cancel_url` must be `https`, or `http` on `localhost`.
- **Embedded:** `ui_mode: :embedded` shows the provider's form inside the site's own page. It takes
  one `return_url` instead of `success_url` and `cancel_url`, and answers `:client_secret` (no
  `:url`). Give the secret to that buyer's page only; Stripe.js mounts the form with it. The
  provider needs `:embedded_checkout`.
- **Pay later:** `capture: :manual` (one-time checkouts only) holds the money on the card. The
  payment reads `:authorized` until `capture_payment/4` takes it (all, or `amount:`) or
  `cancel_payment/3` lets it go. A hold ends by itself after some days (Stripe: 7). The provider
  needs `:capture`.
- A checkout's `customer:` names the buyer by `id` (a customer made with `create_customer/1`) or by
  `email`, never both.

## Checkout options and discounts

```elixir
{:ok, coupon} =
  MishkaPay.create_coupon(%{provider: "stripe", tenant: site.id, name: "Spring",
                            percent_off: 20, duration: :once})

{:ok, code} =
  MishkaPay.create_promotion_code(%{provider: "stripe", tenant: site.id,
                                    coupon_id: coupon.id, code: "SPRING20"})

MishkaPay.checkout(%{
  # ...items, URLs, reference as above
  allow_promotion_codes: true,            # the buyer types SPRING20 on the provider's page
  # or: discounts: [%{promotion_code_id: code.id}]   # applied for them; one way, not both
  automatic_tax: true, locale: "de", billing_address: :required, tax_id_collection: true,
  customer_creation: :always,             # one-time checkouts only
  invoice: true,                          # an invoice for a one-time payment (subscriptions make their own)
  expires_at: DateTime.add(DateTime.utc_now(), 3600)
})
```

- A price's `tax_behavior` is `:exclusive` (tax added on top) or `:inclusive` (the amount holds
  the tax), on catalog prices and on checkout items alike.
- A coupon takes `percent_off` (more than 0, at most 100) or `amount_off` (money), one of them;
  `duration: :repeating` needs `duration_in_months`.
- A checkout read back has `amount_discount` beside `amount_total` and `amount_tax`.
- A checkout that ships: `shipping_countries: ["NL", "DE"]` asks for the address, and
  `shipping_rates: ["shr_...", %{name: "Post", amount: money, min_days: 2, max_days: 5}]` are the
  choices (one-time checkouts only; the provider needs `:shipping`). Read back,
  `:shipping_address` (a `MishkaPay.Address`), `:shipping_rate_id` and `:amount_shipping` say
  where it goes and what shipping cost.
- `expire_checkout/3` ends an open checkout when the buyer walks away, so held stock is free again.
- A provider refuses an option it cannot send (`Errors.Unsupported`); it never drops one.

## The catalog

```elixir
{:ok, product} =
  MishkaPay.create_product(%{provider: "stripe", tenant: site.id, id: "ebook",
                             name: "Elixir ebook", tax_code: "txcd_10302000"})

{:ok, price} =
  MishkaPay.create_price(%{provider: "stripe", tenant: site.id, product_id: product.id,
                           amount: %{amount: "19.99", currency: "USD"}, lookup_key: "ebook"})

MishkaPay.checkout(%{..., items: [%{id: price.id, quantity: 1}]})
```

- A price's amount never changes: make a new price and `archive_price/3` the old one.
- `archive_product/3` takes a product off sale; a provider never deletes what sold.
- `lookup_key` names a price for the host (`list_prices(p, t, lookup_key: "ebook")`), so code
  never keeps a `price_...` id by hand.

## Payment links

A page that sells catalog prices to anyone who opens it: made once, put on a page, an email or a
QR code. Each buyer still gets their own checkout, so sales come in by the same webhooks.

```elixir
{:ok, link} =
  MishkaPay.create_payment_link(%{provider: "stripe", tenant: site.id,
                                  items: [%{id: price.id, quantity: 1}],
                                  success_url: url(~p"/thanks"),
                                  max_purchases: 100,           # left out: no limit; 1: one-time
                                  inactive_message: "Sold out",
                                  quantity_min: 1, quantity_max: 5,
                                  invoice: true, allow_promotion_codes: true})

MishkaPay.PaymentLink.url(link, reference: order.id, email: user.email)
MishkaPay.update_payment_link(%{provider: "stripe", tenant: site.id, id: link.id, active: false})
```

- Every limit is the caller's choice; an option left out is the provider's default.
- `url/2` fills one buyer's details; the `reference` comes back as the checkout's `:reference`.
- A link cannot be deleted: turn it off. `:purchases` counts sales against `:max_purchases`.

## Customers and the portal

Make one provider customer per user and keep its id with the user; a returning buyer then pays
as that customer (`customer: %{id: id}`), and the portal shows their cards, invoices and
subscriptions.

```elixir
{:ok, customer} =
  MishkaPay.create_customer(%{provider: "stripe", tenant: site.id, email: user.email,
                              name: user.name, reference: user.id})

{:ok, portal} =
  MishkaPay.portal_session(%{provider: "stripe", tenant: site.id, customer_id: customer.id,
                             return_url: url(~p"/account")})

redirect(conn, external: portal.url)
```

- `reference` is the host's user id. Sent again within a day with the same fields, it answers the
  same customer instead of a second one; with other fields Stripe refuses it (`Errors.Rejected`,
  status 400). Change a customer with `update_customer/1`.
- What buyers may do in the portal is a `MishkaPay.PortalConfiguration`, kept at the provider:

  ```elixir
  {:ok, teams} =
    MishkaPay.create_portal_configuration(%{provider: "stripe", tenant: site.id, name: "Teams",
      headline: "Acme billing", invoice_history: true, payment_method_update: true,
      customer_update: [:email, :tax_id], subscription_cancel: :at_period_end,
      subscription_update: [:price, :quantity], proration: :create_prorations,
      plans: [%{product_id: team.id, price_ids: [monthly.id, yearly.id]}]})

  MishkaPay.portal_session(%{..., configuration: teams.id})
  ```

  Every field is optional; a change (`update_portal_configuration/1` with `:id`) sends only what it
  names. A list of choices (`customer_update`, `subscription_update`) turns its feature on, `[]`
  off; `subscription_cancel` is `:immediately`, `:at_period_end` or `:off`. A provider never
  deletes one: `active: false` turns it off. The provider's default one (`:default`) serves a
  session without `configuration:`.
- `return_url` follows the checkout URL rule. A customer the provider deleted reads back as
  `Errors.Rejected` with code `"customer_deleted"`.
- A person's erase request: `delete_customer/3` (or the Ash customer's `:remove`). It cannot be
  undone, and it ends their running subscriptions at once; past payments and invoices stay at the
  provider. Delete the host's own copy of their details as well.

## Raw calls

`MishkaPay.request/1` reaches what Mishka Pay does not model yet, with the tenant's keys and the
same retries, idempotency keys, telemetry (`:raw_request`) and errors as every typed call:

```elixir
MishkaPay.request(%{provider: "stripe", tenant: site.id, path: "/v1/tax/settings"})
```

- `:path` is the API path from the root. An address (`"https://evil.test/x"`, `"//evil.test"`),
  a dot segment, a query or an encoded slash is `Errors.Invalid` on `:path` before any request,
  so the keys never leave the provider's host. Put the query in `:params`.
- Give a write a `:reference` so it happens once.
- The answer is the provider's own shape: move to the typed call once one exists.

## Errors

Match the error's struct. Show people plain words, never `inspect(error)`:
`MishkaPay.Ash.message(error)` with the Ash layer (it also drops Ash breadcrumbs), or
`Exception.message(error)` without it.

| Error | Means | Do |
|---|---|---|
| `MishkaPay.Errors.Invalid` | bad input; `errors` has each field | show it on the field |
| `MishkaPay.Errors.Declined` | the card or buyer was declined (`reason`) | ask for another payment method |
| `MishkaPay.Errors.Rejected` | the provider refused the request (`status`, `code`, `param`: the field, by Mishka Pay's name when it has one) | log it (its `message` is the provider's own words, for the log only); often keys or ids |
| `MishkaPay.Errors.Refused` | the host's own checkout gate said no | show its reason |
| `MishkaPay.Errors.Unsupported` | the provider cannot do it (`operation`) | pick another provider or path |
| `MishkaPay.Errors.MissingCredentials` | no keys for that provider and tenant | the site must add keys |
| `MishkaPay.Errors.UnknownProvider` | no such provider installed | supervise the provider |
| `MishkaPay.Errors.Unreachable` | no answer from the provider | retry later; nothing was charged twice |

A request the provider limited (HTTP 429) is a `Rejected` whose message says to try again in a
moment; its `rate_limit_reason` says why when the provider told (Stripe: `"global-rate"`,
`"endpoint-concurrency"`...). Mishka Pay has already retried it, a write only with its
idempotency key, and follows the provider's own word on whether a retry is safe.

`Rejected` and `Declined` keep the provider's id of the failed request as `request_id` (Stripe's
`Request-Id`, `req_...`; PayPal's debug id) and its page about the error as `doc_url`. Log them and
quote the id to the provider's support; never show them to a buyer (`Exception.message/1` and
`MishkaPay.Ash.message/1` leave them out). Behind an Ash action, `MishkaPay.Ash.provider_error(error)`
finds the provider's error inside the Ash error:

```elixir
with {:error, error} <- MishkaPay.refund(attrs) do
  Logger.warning("refund failed", request_id: Map.get(error, :request_id))
  {:error, MishkaPay.Ash.message(error)}
end
```

## Refunds

```elixir
MishkaPay.refund(%{provider: "stripe", tenant: site.id, payment_id: "pi_...",
                   amount: %{amount: "5", currency: "USD"}, reason: :requested_by_customer})
```

- Leave `amount` out for the whole payment. `reason` is `:requested_by_customer`, `:duplicate` or
  `:fraudulent` (Stripe then blocks that card in the account's Radar: use it only for real fraud).
- The tenant's `refunds:` setting decides how often: `:once` (default) refuses a second refund on
  the same payment; `:many` allows part refunds until it is used up, **each with its own
  `reference:`** (required then).

## Real time

One line broadcasts every payment, subscription, customer and dispute change on your own PubSub:

```elixir
defmodule MyApp.Pay.Broadcast do
  use MishkaPay.PubSub, pubsub: MyApp.PubSub    # kinds:, prefix:, priority: are options
end
# application children, after the PubSub: MyApp.Pay.Broadcast

Phoenix.PubSub.subscribe(MyApp.PubSub, MishkaPay.PubSub.topic(:payment, site.id))
def handle_info({:mishka_pay, :payment, %{payment: payment, record: row}}, socket), do: ...
```

Each change goes to the kind's topic (`"mishka_pay:payments"`) and its tenant's
(`"mishka_pay:site-42:payments"`): in a multi-site project subscribe each site to its own. For
other work (email, access rights) listen with your own mishka_installer plugin:

```elixir
defmodule MyApp.Pay.Access do
  use MishkaInstaller.Event.Hook, event: "mishka_pay:dispute:changed"

  @impl true
  def call(%{dispute: dispute} = state) do
    MyApp.Downloads.hold(dispute.payment_id, dispute.status)
    {:reply, state}
  end
end
```

The event names live in `MishkaPay.Events` (`checkout_before/0`, `credentials/0`,
`webhook_received/0`, `event_process/0`, `payment_changed/0`, `subscription_changed/0`,
`customer_changed/0`, `dispute_changed/0`, `providers/0`). A listener answers its state, so return `{:reply, state}` even when it does
nothing. Supervise every listener like any child.

## Rules for an agent writing payment code

- Pass `tenant` through every call in a multi-site project; take keys only from the keys plugin.
- Set `reference` on every checkout and every `:many` refund.
- Read the payment again from the provider before giving access or shipping; a success URL or
  a webhook body alone is not proof of payment.
- Keep amounts as strings or `Money`; let Mishka Pay check currencies and decimals.
- Give access from the payment's or subscription's **status** (`:paid`, `:active`, `:trialing`),
  and take it away on `:refunded`, `:canceled`, `:past_due`/`:unpaid`, or a payment `disputed`,
  as the product decides.
- Answer every listener with `{:reply, state}`; mark a failed webhook listener with
  `%{state | failed: "reason"}` so the provider sends the event again.
- Test with `MishkaPay.Test` (`usage-rules/testing.md`); never call a live provider from tests.
- Use test keys (`sk_test_...`) everywhere outside production.

## Sub-rules: load the one for your task

| Sub-rule | Load it when |
|---|---|
| `usage-rules/stripe.md` | anything Stripe: checkout, Managed Payments, ids, test cards, test clocks |
| `usage-rules/subscriptions.md` | plans, trials, cancel and resume, invoices, renewals |
| `usage-rules/webhooks.md` | the webhook endpoint, signatures, tenants, answers, listeners |
| `usage-rules/ash.md` | storing events, payments, subscriptions, customers or disputes in Ash resources |
| `usage-rules/testing.md` | tests of code that takes payments |
| `usage-rules/providers.md` | writing a new provider, or a capability for one |
| `usage-rules/paypal.md` | PayPal (coming soon) |

## With the usage_rules package

```elixir
# mix.exs, deps
{:usage_rules, "~> 1.3", only: :dev}

# mix.exs, project/0
usage_rules: [
  file: "AGENTS.md",
  usage_rules: [{:mishka_pay, sub_rules: ["stripe", "subscriptions", "webhooks"]}],
  skills: [package_skills: [:mishka_pay]]
]
```

Then `mix usage_rules.sync`. `{:mishka_pay, sub_rules: [...]}` inlines this file and the sub-rules
named (checked with usage_rules 1.3); a bare `:mishka_pay` inlines this file and every sub-rule;
`{:mishka_pay, link: :markdown}` links instead of inlining. `package_skills` installs the
`mishka-pay` skill this package ships (`usage-rules/skills/mishka-pay/SKILL.md`).

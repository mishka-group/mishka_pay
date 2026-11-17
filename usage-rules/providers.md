# Rules for writing a Mishka Pay provider

A provider is one module that `use MishkaPay.Provider`, supervised as a plugin. The full guide is
the repository's `.claude/skills/mishka-pay-provider` skill; Stripe and PayPal are the examples.

```elixir
defmodule MyApp.Pay.Acme do
  use MishkaPay.Provider,
    id: "acme",
    label: "Acme Pay",
    capabilities: [:checkout, :refund, :webhook]

  @impl MishkaPay.Provider
  def checkout(%MishkaPay.Checkout{} = checkout, keys), do: ...
  # one callback per operation of each capability
end
```

- Capabilities and their callbacks (`MishkaPay.Provider.operations/1`); the module does not
  compile with one missing:
  - `:checkout`: `checkout/2`, `fetch_checkout/2`, `fetch_payment/2`;
  - `:embedded_checkout`: no callback; `checkout/2` also takes `ui_mode: :embedded`;
  - `:capture`: `capture_payment/3`, `cancel_payment/2`; `checkout/2` also takes `capture: :manual`;
  - `:expire`: `expire_checkout/2`;
  - `:payment_list`: `list_payments/2`;
  - `:refund`: `refund/2`;
  - `:refund_read`: `fetch_refund/2`, `list_refunds/2`;
  - `:subscription`: `fetch_subscription/2`, `cancel_subscription/3`, `resume_subscription/2`,
    `list_invoices/2`, `fetch_invoice/2`;
  - `:subscription_change`: `change_subscription/2`, `preview_subscription_change/2`,
    `pause_collection/3`, `resume_collection/2`;
  - `:subscription_list`: `list_subscriptions/2` (`:customer_id`, `:price_id`, `:status`),
    `search_subscriptions/2` (`:status`, `:reference`, `:metadata`); leave it out when the
    provider has subscriptions but no list of them (PayPal);
  - `:subscription_schedule`: `create_subscription_schedule/2`, `fetch_subscription_schedule/2`,
    `list_subscription_schedules/2` (`:customer_id`, `:scheduled`), `update_subscription_schedule/2`,
    `release_subscription_schedule/2`, `cancel_subscription_schedule/3` (`:invoice_now`,
    `:prorate`);
  - `:invoice`: `create_invoice/2`, `finalize_invoice/2`, `send_invoice/2`, `pay_invoice/3`,
    `void_invoice/2`, `mark_invoice_uncollectible/2`, `delete_invoice/2`;
  - `:invoice_item`: `create_invoice_item/2`, `update_invoice_item/2`, `delete_invoice_item/2`,
    `list_invoice_items/2` (`:customer_id`, `:invoice_id`, `:pending`); a provider that bills but
    keeps no charges between bills leaves it out;
  - `:credit_note`: `create_credit_note/2`, `preview_credit_note/2`, `fetch_credit_note/2`,
    `void_credit_note/2`, `list_credit_notes/2` (`:invoice_id`, `:customer_id`),
    `list_credit_note_lines/3`;
  - `:event_list`: `list_events/2`; optional `check_keys/1` (one read that changes nothing);
  - `:raw_request`: `raw_request/2` (a `MishkaPay.RawRequest`, answered as the provider's decoded
    map); refuse an option of `:options` the provider cannot send;
  - `:customer`: `create_customer/2`, `fetch_customer/2`, `update_customer/2`, `list_customers/2`;
  - `:tax_id`: `create_tax_id/2`, `list_tax_ids/2` (`:customer_id` in its options),
    `delete_tax_id/3`;
  - `:tax`: `calculate_tax/2`, `record_tax/3`;
  - `:shipping`: `create_shipping_rate/2`, `list_shipping_rates/2`; the checkout sends its
    `:shipping_countries` and `:shipping_rates`, and reads back `:shipping_address`,
    `:shipping_rate_id` and `:amount_shipping`;
  - `:portal`: `portal_session/2`, `create_portal_configuration/2`,
    `update_portal_configuration/2`, `fetch_portal_configuration/2`,
    `list_portal_configurations/2` (`:active`, `:default`);
  - `:payment_method`: `list_payment_methods/2`, `fetch_payment_method/2`,
    `detach_payment_method/2`, `set_default_payment_method/3`; a checkout in `mode: :setup` needs
    it too;
  - `:discount`: `create_coupon/2`, `fetch_coupon/2`, `list_coupons/2`, `delete_coupon/2`,
    `create_promotion_code/2`, `fetch_promotion_code/2`, `list_promotion_codes/2`,
    `update_promotion_code/2`;
  - `:payment_link`: `create_payment_link/2`, `fetch_payment_link/2`, `list_payment_links/2`,
    `update_payment_link/2`;
  - `:catalog`: `create_product/2`, `fetch_product/2`, `update_product/2`, `list_products/2`,
    `create_price/2`, `fetch_price/2`, `update_price/2`, `list_prices/2`;
  - `:file`: `upload_file/2` (checks the provider's types and size first), `fetch_file/2`,
    `file_link/3`; an upload is `MishkaPay.Client`'s `multipart` body;
  - `:usage`: `create_meter/2`, `fetch_meter/2`, `update_meter/2` (a new name only),
    `list_meters/2`, `deactivate_meter/2`, `reactivate_meter/2`, `report_usage/2`,
    `cancel_usage/2` (a `MishkaPay.UsageCancellation`, once per report), `usage_summary/3`;
  - `:entitlement`: `create_feature/2`, `attach_feature/3`, `list_entitlements/2`;
  - `:balance`: `fetch_balance/1`, `list_balance_transactions/2`;
  - `:customer_balance`: `adjust_customer_balance/2`, `list_customer_balance/2`;
  - `:fraud`: `fetch_fraud_warning/2`, `list_fraud_warnings/2` (`:payment_id`, `:charge_id`),
    `fetch_fraud_review/2`, `list_fraud_reviews/2` (open ones), `approve_fraud_review/2`;
  - `:intent`: `create_payment_intent/2`, `fetch_payment_intent/2`, `update_payment_intent/2`,
    `confirm_payment_intent/3` and `confirm_setup_intent/3` (the id, then `:payment_method_id`
    and `:return_url`), `cancel_payment_intent/2`, `create_setup_intent/2`,
    `fetch_setup_intent/2`, `cancel_setup_intent/2`; each answers the intent with its
    `:client_secret`;
  - `:tax_rate`: `create_tax_rate/2`, `fetch_tax_rate/2`, `update_tax_rate/2` (never the
    percentage or `:inclusive`), `list_tax_rates/2` (`:active`, `:inclusive`); a line's or a
    bill's `:tax_rate_ids` it cannot send are refused, never dropped;
  - `:tax_setup`: `create_tax_registration/2`, `list_tax_registrations/2` (`:status`),
    `expire_tax_registration/3` (the registration's id and when, `nil` for now),
    `fetch_tax_settings/1`, `update_tax_settings/2`;
  - `:connect`: `create_connected_account/2`, `fetch_connected_account/3` (`:api`),
    `update_connected_account/2`, `list_connected_accounts/2` (`:api`, `:configurations`,
    `:closed`), `close_connected_account/3` (`:api`, `:reason`), `account_link/2`, `login_link/2`, `fetch_application_fee/2`,
    `list_application_fees/2` (`:charge_id`), `refund_application_fee/3` (`:amount`,
    `:reference`, `:tenant`), and a checkout's `:destination`, `:on_behalf_of`,
    `:application_fee` and `:application_fee_percent`; the tenant's keys' `:account_id` is the
    account every request acts for, and its webhooks take only that account's events;
  - `:transfer`: `create_transfer/2`, `fetch_transfer/2`, `list_transfers/2` (`:destination`,
    `:transfer_group`), `reverse_transfer/3` (`:amount`, `:reference`, `:tenant`);
  - `:payout`: `fetch_payout/2`, `list_payouts/2` (`:status`), `cancel_payout/2`;
  - `:webhook`: `verify_webhook/3`.
- Every `list_*` callback takes the options keyword (`:limit`, `:after` and its filters) and
  answers one `MishkaPay.Page`; `:next` is the provider's own cursor.
- A checkout option the provider cannot send (`discounts`, `locale`, `expires_at`...) is refused
  with `Errors.Unsupported`, never dropped.
- Leave a capability out rather than half-implement it; Mishka Pay answers `Errors.Unsupported`.
- Every callback answers the Mishka Pay struct or a `MishkaPay.Errors` error, never the provider's
  raw body; only `raw_request/2` answers the provider's decoded answer, which is its point.
- Requests go through `MishkaPay.Client` (retries, idempotency keys, telemetry).
- Use `MishkaPay.ProviderKit` for the refund rule (`refund_key/2`, `refundable/3`), idempotency
  keys and `invalid/2`; do not copy them.
- Check ids by shape before they reach a URL path; refuse what the provider cannot do before any
  request.
- Test with a stand-in that answers in the provider's shapes, and `use MishkaPay.ProviderCase`.

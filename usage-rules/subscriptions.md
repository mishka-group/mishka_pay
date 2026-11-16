# Rules for subscriptions in Mishka Pay

A subscription starts with a checkout in `mode: :subscription`; the provider needs the
`:subscription` capability (Stripe has it; PayPal not yet), or the checkout is
`Errors.Unsupported`.

```elixir
MishkaPay.checkout(%{
  provider: "stripe",
  tenant: site.id,
  mode: :subscription,
  trial_days: 14,
  items: [%{name: "Pro plan", amount: %{amount: "9", currency: "USD"},
            interval: :month, interval_count: 1, tax_code: "txcd_10103001"}],
  success_url: url(~p"/welcome") <> "?session_id={CHECKOUT_SESSION_ID}",
  cancel_url: url(~p"/pricing"),
  reference: account.id
})
```

- Every item of a subscription checkout needs `interval` (`:day`, `:week`, `:month`, `:year`) or a
  provider price `id`. A one-time checkout refuses an item with an interval, and `trial_days`.
- Back on the success page, `fetch_checkout/3` gives `:subscription_id`; read the subscription
  with `fetch_subscription/3`.

## Statuses and access

| Status | Means | Access |
|---|---|---|
| `:trialing` | in the free trial | give |
| `:active` | paid for the current period | give |
| `:past_due` | a renewal failed; the provider tries again | the product decides (grace period) |
| `:unpaid` | the retries ran out | take away |
| `:canceled` | ended | take away |
| `:incomplete`, `:incomplete_expired` | the first payment never finished | do not give |
| `:paused` | paused | take away |

`cancel_at_period_end: true` means it still runs until `current_period_end`, then ends.

## Changing it

- `MishkaPay.cancel_subscription(provider, id, tenant)` cancels at the period's end (the buyer
  keeps what they paid for); `at: :now` ends it at once.
- `MishkaPay.resume_subscription(provider, id, tenant)` takes back a cancel set for the period's
  end. A subscription already canceled cannot be resumed: a new checkout starts a new one.
- `MishkaPay.list_invoices(provider, tenant, subscription_id: id)` lists its bills page by page,
  newest first (`customer_id:` lists a customer's), with `:hosted_url` and `:pdf_url` for the
  buyer. An `:open` invoice is not paid yet.

## Changing a running subscription

```elixir
change = %{provider: "stripe", tenant: site.id, subscription_id: sub.id,
           price_id: team_price.id,          # a new plan; left out, the plan stays
           quantity: 5,                      # seats; left out, it stays
           proration: :always_invoice}       # or :create_prorations (default) or :none

{:ok, preview} = MishkaPay.preview_subscription_change(change)   # an Invoice with proration lines
{:ok, sub} = MishkaPay.change_subscription(Map.put(change, :proration_date, preview_date))
```

- `preview_subscription_change/1` sets `:proration_date` to now when it is not given; pass the
  same date to `change_subscription/1` so it bills exactly the preview's `amount_due`.
- A subscription of several items needs `item_id:` (each item's `:item_id`).
- `billing_cycle_anchor: :now` starts a new period at once; `payment_behavior:` says what happens
  when charging the difference fails. Every option left out is the provider's default.
- `MishkaPay.pause_collection(p, id, tenant, behavior: :void | :keep_as_draft |
  :mark_uncollectible, resumes_at: datetime)` stops charging without cancelling;
  `resume_collection/3` starts again.
- `MishkaPay.fetch_invoice(p, invoice_id, tenant)` reads one bill with its `:lines`; a credit line
  for unused time has a negative `:amount`.
- Usage-based billing is not in Mishka Pay yet.

## Keep access right

Do not compute access from dates yourself. Listen to `mishka_pay:subscription:changed` (or the
Ash subscription row), and give or take access from `status`. With the Ash layer, the inbox
listener keeps the row current from `invoice.*` and `customer.subscription.*` webhooks.

# Rules for subscriptions in Mishka Pay

A subscription starts with a checkout in `mode: :subscription`; the provider needs the
`:subscription` capability (Stripe and PayPal have it; PayPal sells one price per subscription,
see `usage-rules/paypal.md`), or the checkout is `Errors.Unsupported`.

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
- `billing_mode:` (`:flexible` or `:classic`) says how the provider counts prorations and bills;
  `proration_discounts:` (`:itemized` or `:included`) how a bill shows the proration of a
  discounted price, in the flexible mode only. Left out, the site's keys decide
  (`MishkaPay.Credentials`), else `:flexible` and `:itemized`, Stripe's recommended ones. Both
  belong to a subscription checkout or a new schedule: a one-time checkout, a schedule made from a
  subscription and a schedule change refuse them, and `proration_discounts` with `:classic` is
  `Errors.Invalid`.

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

## Finding them

```elixir
MishkaPay.list_subscriptions("stripe", site.id, customer_id: customer.id, status: :all)
MishkaPay.list_subscriptions("stripe", site.id, price_id: pro.id, status: :past_due, limit: 50)
MishkaPay.search_subscriptions("stripe", site.id, reference: account.id)
MishkaPay.search_subscriptions("stripe", site.id, status: :active, metadata: %{"plan" => "pro"})
```

- Both answer a `MishkaPay.Page` (`limit:`, `after:`) and need the provider's
  `:subscription_list` capability: Stripe has it; PayPal has no list of subscriptions and refuses
  with `Errors.Unsupported` before any request.
- `status:` is one of `MishkaPay.Subscription.statuses/0`; a list also takes `:all`. Without it a
  list may leave ended subscriptions out (Stripe leaves `:canceled` out). Anything else is
  `Errors.Invalid` on `:status`.
- A search needs `status:`, `reference:` (the checkout's `reference`) or `metadata:`, all of which
  must match. A subscription just made may take a minute to be found: read one you know by id with
  `fetch_subscription/3`.

## Changing it

- `MishkaPay.cancel_subscription(provider, id, tenant)` cancels at the period's end (the buyer
  keeps what they paid for); `at: :now` ends it at once.
- `MishkaPay.resume_subscription(provider, id, tenant)` takes back a cancel set for the period's
  end. A subscription already canceled cannot be resumed: a new checkout starts a new one.
- `MishkaPay.list_invoices(provider, tenant, subscription_id: id)` lists its bills page by page,
  newest first (`customer_id:` lists a customer's), with `:hosted_url` and `:pdf_url` for the
  buyer. An `:open` invoice is not paid yet. `status: :paid, limit: 1` is its latest paid bill,
  and `payment_id` names the payment that paid it: sync that one as the subscription's payment.

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
- A `:proration_date` goes only with prorations: not with `proration: :none`, and not with
  `billing_cycle_anchor: :now` (both are refused before the provider).
- A subscription of several items needs `item_id:` (each item's `:item_id`).
- `billing_cycle_anchor: :now` starts a new period at once; `payment_behavior:` says what happens
  when charging the difference fails. Every option left out is the provider's default.
- `MishkaPay.pause_collection(p, id, tenant, behavior: :void | :keep_as_draft |
  :mark_uncollectible, resumes_at: datetime)` stops charging without cancelling;
  `resume_collection/3` starts again.
- `MishkaPay.fetch_invoice(p, invoice_id, tenant)` reads one bill with its `:lines`; a credit line
  for unused time has a negative `:amount`.
- Usage-based billing (meters, usage reports) is Stripe's `:usage` capability: see the usage
  billing section of `usage-rules/stripe.md`.
- A one-off charge on the next renewal (a setup fee, an extra seat this month) is an invoice item:
  `MishkaPay.create_invoice_item(%{provider: "stripe", tenant: site.id, customer_id: id,
  name: "Setup fee", amount: money, reference: r})`. Without `:invoice_id` it waits for the
  customer's next bill, a renewal included; `list_invoice_items/3` with `pending: true` shows what
  waits, and `delete_invoice_item/3` takes one back before that bill is finalized. Its
  `:reference` makes it charge once. The provider needs `:invoice_item` (Stripe has it, PayPal
  not).

## Planning changes ahead: schedules

A change on a set date, an intro price, a membership that stops after twelve months: a
subscription schedule, in phases. The provider needs `:subscription_schedule` (Stripe has it,
PayPal not).

```elixir
# New: the subscription starts with the first phase.
MishkaPay.create_subscription_schedule(%{provider: "stripe", tenant: site.id,
  customer_id: customer.id, end_behavior: :cancel, reference: "member-" <> member.id,
  phases: [%{items: [%{id: intro.id}], iterations: 3, interval: :month, trial: true},
           %{items: [%{id: full.id, quantity: 2}], end_at: ~U[2027-12-01 00:00:00Z]}]})

# From a running subscription, then its next phase.
{:ok, schedule} = MishkaPay.create_subscription_schedule(%{provider: "stripe", subscription_id: sub.id})
now = Enum.at(schedule.phases, schedule.current_phase)

MishkaPay.update_subscription_schedule(%{provider: "stripe", id: schedule.id, end_behavior: :release,
  phases: [%{items: now.items, start_at: now.start_at, end_at: change_at},
           %{items: [%{id: team.id}], iterations: 1, interval: :month}]})
```

- A phase charges catalog prices by id, for `:iterations` periods of `:interval`, or until
  `:end_at`, not both; the last one may leave both out (one period of its prices). `trial: true`
  makes the phase a free trial; `:proration` says how its change of price is billed.
- A change replaces the phases from the current one on: name the current one with the
  `:start_at` it has. A schedule made from a subscription takes nothing else: no customer, phases,
  start or end behavior (change them after).
- `:end_behavior` is `:release` (the subscription goes on as the last phase left it) or `:cancel`.
- `release_subscription_schedule/3` ends the plan and keeps the subscription;
  `cancel_subscription_schedule/4` ends both now (`invoice_now:`, `prorate:`).
- `:current_phase` is the index of the phase running now; `:subscription_id` the subscription
  it runs, `:released_subscription_id` the one it let go. A subscription names its schedule as
  `:schedule_id`.

## Keep access right

Do not compute access from dates yourself. Listen to `mishka_pay:subscription:changed` (or the
Ash subscription row), and give or take access from `status`. With the Ash layer, the inbox
listener keeps the row current from `invoice.*` and `customer.subscription.*` webhooks.

## Further reading

The Mishka Pay docs on mishka.tools explain each area with full examples:

- [Sell and manage subscriptions](https://mishka.tools/pay/docs/subscriptions)
- [Bill by usage with meters](https://mishka.tools/pay/docs/usage-billing)

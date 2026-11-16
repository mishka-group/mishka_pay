# Webhooks

`MishkaPay.Webhook` takes each provider's signed messages at
`/pay/webhooks/<provider>/<tenant>`, checks the signature with that tenant's `webhook_secret`, and
hands a `MishkaPay.Event` to the `mishka_pay:webhook:received` listeners. It must come before
`Plug.Parsers` (it needs the raw body).

In Stripe's Dashboard, point each site's endpoint at
`https://your-host/pay/webhooks/stripe/<site id>` and send it the events of
`MishkaPay.Providers.Stripe.handled_events/0`:

| Stripe event | Updates |
|---|---|
| `checkout.session.completed` | the payment, or the subscription it started |
| `checkout.session.expired`, `checkout.session.async_payment_succeeded`, `checkout.session.async_payment_failed` | the payment |
| `payment_intent.succeeded`, `payment_intent.payment_failed`, `payment_intent.canceled`, `payment_intent.processing`, `payment_intent.requires_action`, `payment_intent.amount_capturable_updated` | the payment |
| `charge.succeeded`, `charge.failed`, `charge.refunded`, `charge.captured`, `charge.expired` | the payment |
| `refund.created`, `refund.updated`, `refund.failed` | the payment |
| `invoice_payment.paid` | the payment an invoice was paid with |
| `charge.dispute.created`, `charge.dispute.updated`, `charge.dispute.closed`, `charge.dispute.funds_withdrawn`, `charge.dispute.funds_reinstated` | the dispute and its payment |
| `invoice.paid`, `invoice.payment_failed`, `invoice.finalized`, `invoice.payment_action_required`, `invoice.voided`, `invoice.marked_uncollectible`, `invoice.overdue`, `invoice.upcoming` | the subscription |
| `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `customer.subscription.paused`, `customer.subscription.resumed`, `customer.subscription.trial_will_end` | the subscription |
| `customer.created`, `customer.updated`, `customer.deleted` | the customer |

Each listed event is tested to name what it updates. Any other event is verified and stored, and
changes nothing.

## Listeners

Without Ash, listen on `mishka_pay:webhook:received` and read the object again from the provider
(the webhook body is never proof):

```elixir
defmodule MyApp.Pay.OnEvent do
  use MishkaInstaller.Event.Hook, event: "mishka_pay:webhook:received"

  @impl true
  def call(%{event: %MishkaPay.Event{payment_id: id, tenant: site}} = state) when is_binary(id) do
    {:ok, payment} = MishkaPay.fetch_payment(state.event.provider, id, site)
    MyApp.Orders.paid(payment)
    {:reply, state}
  end

  def call(state), do: {:reply, state}
end
```

Answer `%{state | failed: "reason"}` when the work did not happen: the endpoint answers 500 and
the provider sends the event again. With the Ash layer, the inbox stores every event once and works
it as an Oban job with retries; see the Ash guide.

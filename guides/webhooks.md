# Webhooks

`MishkaPay.Webhook` takes each provider's signed messages at
`/pay/webhooks/<provider>/<tenant>`, checks the signature with that tenant's `webhook_secret`, and
hands a `MishkaPay.Event` to the `mishka_pay:webhook:received` listeners. It must come before
`Plug.Parsers` (it needs the raw body).

In Stripe's Dashboard, point each site's endpoint at
`https://your-host/pay/webhooks/stripe/<site id>` and send it the events of
`MishkaPay.Providers.Stripe.handled_events/0`:

| Stripe events | Updates |
|---|---|
| `checkout.session.*` | the payment, or the subscription it started |
| `payment_intent.*`, `charge.*`, `refund.*`, `invoice_payment.paid` | the payment |
| `charge.dispute.*` | the dispute and its payment |
| `invoice.paid`, `.payment_failed`, `.finalized`, `customer.subscription.*` | the subscription |
| `customer.created`, `.updated`, `.deleted` | the customer |

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

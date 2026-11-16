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
  - `:refund`: `refund/2`;
  - `:subscription`: `fetch_subscription/2`, `cancel_subscription/3`, `resume_subscription/2`,
    `list_invoices/2`;
  - `:webhook`: `verify_webhook/3`.
- Leave a capability out rather than half-implement it; Mishka Pay answers `Errors.Unsupported`.
- Every callback answers the Mishka Pay struct or a `MishkaPay.Errors` error, never the provider's
  raw body.
- Requests go through `MishkaPay.Client` (retries, idempotency keys, telemetry).
- Use `MishkaPay.ProviderKit` for the refund rule (`refund_key/2`, `refundable/3`), idempotency
  keys and `invalid/2`; do not copy them.
- Check ids by shape before they reach a URL path; refuse what the provider cannot do before any
  request.
- Test with a stand-in that answers in the provider's shapes, and `use MishkaPay.ProviderCase`.

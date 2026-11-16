# Testing

```elixir
# test/test_helper.exs
MishkaPay.Test.setup!()
ExUnit.start()

# config/test.exs
config :mishka_pay, req_options: [plug: {Req.Test, MishkaPay.Client}]
```

- `MishkaPay.Test.put_keys/3` gives keys for a test, `MishkaPay.Test.stub_http/1` answers every
  provider request; both belong to the test process, so tests can be `async: true`.
- `MishkaPay.Test.start_plugin!/1` starts a plugin and returns once its event runs it (no sleeps).
- `MishkaPay.Test.deliver_event/5` posts a Stripe event signed the way Stripe signs it through
  `MishkaPay.Webhook`; `MishkaPay.Test.stripe_object/2` gives one object of each kind.
- Stripe's real request shapes: run `stripe/stripe-mock` and forward `stub_http/1` to it.
- Live sandbox tests behind a tag, with `sk_test_` keys only; renewals and plan changes on Stripe
  test clocks. `mix mishka_pay.stripe.clean_clocks` deletes old ones.
- A provider you write: `use MishkaPay.ProviderCase, provider: MyApp.Pay.Acme` runs the contract.

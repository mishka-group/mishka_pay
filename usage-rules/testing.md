# Rules for testing code that uses Mishka Pay

Never call a live provider from tests. Use the test kit, which answers HTTP calls in the test
process and needs no sleeps.

```elixir
# test/test_helper.exs
MishkaPay.Test.setup!()
MishkaPay.Test.await_plugin!(MishkaPay.Providers.Stripe)  # the provider the app starts
ExUnit.start()

# config/test.exs
config :mishka_pay, req_options: [plug: {Req.Test, MishkaPay.Client}]
```

```elixir
test "a paid order gives access" do
  MishkaPay.Test.start_plugin!(MishkaPay.Providers.Stripe)
  MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_1"})
  MishkaPay.Test.stub_http(fn conn ->
    Req.Test.json(conn, %{"id" => "pi_1", "object" => "payment_intent", "status" => "succeeded",
                          "amount" => 1999, "currency" => "usd"})
  end)

  assert {:ok, %MishkaPay.Payment{status: :paid}} = MishkaPay.fetch_payment("stripe", "pi_1")
end
```

- `put_keys/3` and `stub_http/1` belong to the test process and what it starts, so tests that use
  only them can be `async: true`. `start_plugin!/1` changes an event every test sees: `async: false`.
- For Stripe's real request shapes, run Stripe's mock server
  (`docker run -p 12111:12111 stripe/stripe-mock`) and forward to it from `stub_http/1`.
- Wait on messages or telemetry (`:telemetry_test.attach_event_handlers/2`, `assert_receive`),
  never on `Process.sleep`.
- PayPal with no keys and no network: `MishkaPay.Test.PayPal.stub!()` answers as PayPal does
  (Orders, captures, refunds, plans, subscriptions, webhook checks); `MishkaPay.Test.PayPal.order/3`
  and `subscription/3` put one in a state (`"APPROVED"`, `"ACTIVE"`...). A webhook message passes
  PayPal's check when its `paypal-transmission-sig` header is `"good"`.
- `MishkaPay.Test.start_plugin!/1` only awaits a plugin the host's application already runs (a
  host that starts its providers, as Mishka CMS does), so a test can name it either way.
- Sandbox tests run only when the keys are in the environment (`.env` locally); without them the
  stand-ins answer, so CI needs no secrets.
- Test your webhook code without a provider: `MishkaPay.Test.deliver_event(tenant, type, object,
  webhook_secret)` posts a Stripe event signed the way Stripe signs it through
  `MishkaPay.Webhook`; `signed_event/4` gives the `{body, headers}` for your own request, and
  `stripe_object(kind, overrides)` one object of each kind (`:payment_intent`, `:checkout_session`,
  `:charge`, `:refund`, `:dispute`, `:invoice`, `:subscription`, `:customer`).
- `mix mishka_pay.stripe.clean_clocks --tenant site --older-than 2` deletes old Stripe test clocks
  (with their customers and subscriptions); `--dry-run` lists them. Test keys only.
- A provider you write: `use MishkaPay.ProviderCase, provider: MyApp.Pay.Acme` runs the contract
  tests every provider must pass.
- Live sandbox tests go behind a tag excluded unless the sandbox key is set, and accept only test
  keys.

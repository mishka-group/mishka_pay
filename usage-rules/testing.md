# Rules for testing code that uses Mishka Pay

Never call a live provider from tests. Use the test kit, which answers HTTP calls in the test
process and needs no sleeps.

```elixir
# test/test_helper.exs
MishkaPay.Test.setup!()
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
- A provider you write: `use MishkaPay.ProviderCase, provider: MyApp.Pay.Acme` runs the contract
  tests every provider must pass.
- Live sandbox tests go behind a tag excluded unless the sandbox key is set, and accept only test
  keys.

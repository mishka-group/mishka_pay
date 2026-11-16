# Working on mishka_pay

Mishka Pay is a payment SDK for Elixir: providers as mishka_installer plugins (Stripe, PayPal),
per-tenant keys at runtime, verified webhooks, and an optional Ash layer. This file is for agents
changing this repository. An agent *using* Mishka Pay in another project reads the usage rules.

## Read first

- `usage-rules.md` and `usage-rules/*.md`: what the library does and how it is used. They are the
  public contract: when a change moves a call, an option or a struct field, change the rules in the
  same commit (`mix mishka_pay.usage_rules` fails on a name that does not exist).
- `.claude/skills/mishka-code-design/`: how Mishka code is written (Ash, mishka_installer,
  guarded_struct, tests without sleeps, telemetry, commits and PRs). Follow it for every change.
- `.claude/skills/mishka-pay-provider/`: adding a provider or a capability, end to end.

## Layout

| Path | Holds |
|---|---|
| `lib/mishka_pay.ex` | the calls (`checkout/1`, `fetch_payment/3`, `refund/1`, subscriptions) |
| `lib/mishka_pay/provider.ex`, `provider_kit.ex` | the provider contract and the rules every provider shares |
| `lib/mishka_pay/providers/` | Stripe and PayPal adapters; `__<id>/mapper.ex` maps their answers |
| `lib/mishka_pay/ash/` | the optional Ash layer: the `MishkaPay.Ash.Resource` extension (`mishka_pay do kind ... end`), its changes and listeners |
| `lib/mishka_pay/webhook.ex` | the webhook Plug |
| `lib/mishka_pay/test.ex`, `provider_case.ex` | the test kit hosts use |
| `test/support/` | test-only code: stand-ins, Ash resources, `mix ci` checks |
| `examples/shop/` | the demo app: shows every feature, with a `data-testid` on every part |

## Run it

- Tests need Postgres and Stripe's mock server:
  `docker run -d --name mp-postgres -p 127.0.0.1:5433:5432 -e POSTGRES_PASSWORD=postgres -v mp-postgres-data:/var/lib/postgresql/data postgres:17`
  and `docker run -d --name mp-stripe-mock -p 127.0.0.1:12111:12111 stripe/stripe-mock:latest`,
  then `POSTGRES_PORT=5433 mix test`.
- After changing what a kind adds (`ash/__resource/kinds.ex`): `MIX_ENV=test POSTGRES_PORT=5433 mix ash.codegen <name>` (the
  generated migrations are gitignored here; the demo keeps its own).
- Live sandbox tests: `STRIPE_SECRET_KEY=sk_test_... mix test --only stripe_live` (test keys only).
- The full gate is `mix ci`: compile with warnings as errors, format, credo, Credence, the usage
  rules check, Gettext, sobelow, deps audit, dialyzer, ex_dna (no copied code), tests.
- The demo: `cd examples/shop && mix setup && mix phx.server` with a sandbox key in its
  gitignored `.env`; `mix shop.sandbox` fills it with test payments and subscriptions.

## When you change behaviour

1. Code and tests in `lib/` and `test/`; a visible message goes through `MishkaPay.Messages` and
   `mix gettext.extract --merge`.
2. The usage rules that describe it.
3. The demo, so the feature can be tried by hand and by a browser test (a `data-testid` on each
   new part).
4. `mix ci` green, then one commit per change: `type(scope): what the code now does`.

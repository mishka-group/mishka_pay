<div align="center">

[![Hex.pm](https://img.shields.io/hexpm/v/mishka_pay.svg?style=flat-square)](https://hex.pm/packages/mishka_pay)
[![CI](https://img.shields.io/github/actions/workflow/status/mishka-group/mishka_pay/ci.yml?branch=master&style=flat-square)](https://github.com/mishka-group/mishka_pay/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue?style=flat-square)](https://github.com/mishka-group/mishka_pay/blob/master/LICENSE)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-mishka--group-ea4aaa?style=flat-square&logo=github)](https://github.com/sponsors/mishka-group)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy_Me_a_Coffee-mishkagroup-ffdd00?style=flat-square&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/mishkagroup)
[![Discord](https://img.shields.io/badge/Discord-Mishka_Tools-5865F2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/m4zdCJjDJg)

# Mishka Pay

**A [payment SDK for Elixir](https://mishka.tools/pay): one API for Stripe and PayPal, providers as plugins, with or without Ash.**

[Website](https://mishka.tools/pay) · [Documentation](https://mishka.tools/pay/docs) · [Capabilities](https://mishka.tools/pay/docs/capabilities) · [Discord](https://discord.gg/m4zdCJjDJg) · [Hire us](https://mishka.tools/hire-us)

</div>

## 📖 What is Mishka Pay?

Mishka Pay is a payment SDK for Elixir and Phoenix. Checkouts, payments, refunds, subscriptions,
customers and verified webhooks get one shape, whatever the provider. You call
`MishkaPay.checkout/1` and get a checkout, from Stripe or from PayPal.

It is built so one install can serve many sites, each taking its own payments, as
[Mishka CMS](https://mishka.tools/cms) does. It works the same in any Phoenix or plain Elixir
project.

## ✨ Why Mishka Pay

- 🔌 **[Providers are plugins](https://mishka.tools/pay/docs/how-mishka-pay-works#providers-are-plugins)**:
  a provider is a module that implements `MishkaPay.Provider`. Add your own bank or payment
  gateway as a plugin, with no fork of Mishka Pay. A contract test (`MishkaPay.ProviderCase`)
  checks it. The plugin system underneath is [Mishka Installer](https://mishka.tools/installer).
- 💳 **[Stripe in full, PayPal included](https://mishka.tools/pay/docs/capabilities)**: Stripe has
  all 39 capabilities, from checkouts to tax, usage billing and Connect.
  [PayPal](https://mishka.tools/pay/docs/paypal) has a smaller set: checkout, refunds,
  subscriptions, webhooks and raw requests. A call the provider cannot do answers
  `MishkaPay.Errors.Unsupported` before any request.
- 🌐 **[Many sites, one install](https://mishka.tools/pay/docs/keys-and-options)**: every call
  names its tenant (a site). A keys plugin answers each site's keys at runtime, never from
  `config.exs`, so a site's new keys need no restart.
- 🧱 **[With or without Ash](https://mishka.tools/pay/docs/ash-and-cms)**: the core works on plain
  structs built with [GuardedStruct](https://mishka.tools/guarded-struct). With Ash, the
  `MishkaPay.Ash.Resource` extension keeps payments, subscriptions, customers, disputes and more
  in your own resources, kept current from webhooks.
- 📬 **[Verified webhooks](https://mishka.tools/pay/docs/webhooks)**: one endpoint per site checks
  each signature with that site's secret. With Ash, an inbox stores each event once and works it
  as an AshOban job with retries.
- 🔁 **[Subscriptions](https://mishka.tools/pay/docs/subscriptions)**: trials, plan and quantity
  changes with a preview of the bill, paused collection, cancel and resume, and schedules planned
  ahead.
- 🧾 **[Tax and invoices](https://mishka.tools/pay/docs/tax-and-invoices)** and
  **[usage billing](https://mishka.tools/pay/docs/usage-billing)**: Stripe Tax, one-off bills,
  credit notes and meters.
- 🏬 **[One platform, many sellers](https://mishka.tools/pay/docs/connect-platform)**: Stripe
  Connect with Accounts v2, application fees, transfers and payouts.
- 🧩 **Every extension point is an event**: a checkout gate (`mishka_pay:checkout:before`), webhook
  listeners, and `mishka_pay:<kind>:changed` after every change. `MishkaPay.PubSub` sends them to
  Phoenix PubSub in one line.
- 🚦 **[Plain errors and telemetry](https://mishka.tools/pay/docs/errors-and-telemetry)**: every
  call answers `{:ok, struct}` or a typed error with a plain message for people. No telemetry
  event carries a key or a buyer's details.
- 🧪 **[A test kit](https://mishka.tools/pay/docs/test-your-payments)**: stub every provider
  request per test, deliver signed webhooks and run Stripe's mock server, in `async: true` tests.
- 🤖 **Rules for coding agents**: `usage-rules.md` and a `mishka-pay` skill ship with the package,
  so an agent writes payment code with calls that exist.

## 🚀 Get started

Follow **[Get Started](https://mishka.tools/pay/docs)**. In short, in a Phoenix project on Elixir
1.20 or newer:

```bash
mix igniter.install mishka_pay
```

It adds the package, the plugin registry, a keys plugin, the webhook endpoint before
`Plug.Parsers` and the test setup. Add `--ash` for the Ash resources and `--pubsub` for
broadcasts. To set it up by hand, add the package to `mix.exs`. A pre-release is matched only
when you name it:

```elixir
{:mishka_pay, "~> 0.0.2"}
```

Give it a sandbox key and sell:

```bash
export STRIPE_SECRET_KEY=sk_test_...
```

```elixir
{:ok, checkout} =
  MishkaPay.checkout(%{
    provider: "stripe",
    items: [%{name: "Elixir ebook", amount: %{amount: "19.99", currency: "USD"}}],
    success_url: url(~p"/thanks") <> "?session_id={CHECKOUT_SESSION_ID}",
    cancel_url: url(~p"/cart"),
    reference: order.id
  })

redirect(conn, external: checkout.url)
```

When the buyer comes back, read the payment with `MishkaPay.fetch_checkout/3` and
`MishkaPay.fetch_payment/3` before you give access.

## 📚 Documentation

- **Tutorial**: [Get Started](https://mishka.tools/pay/docs)
- **How-to guides**:
  - [Take a one-time payment](https://mishka.tools/pay/docs/take-a-payment)
  - [Sell and manage subscriptions](https://mishka.tools/pay/docs/subscriptions)
  - [Refund, hold and capture a payment](https://mishka.tools/pay/docs/refunds-and-captures)
  - [Save customers and cards, and open the billing portal](https://mishka.tools/pay/docs/customers-and-portal)
  - [Receive and verify webhooks](https://mishka.tools/pay/docs/webhooks)
  - [Run many sites on one Stripe platform](https://mishka.tools/pay/docs/connect-platform)
  - [Count tax, send invoices and issue credit notes](https://mishka.tools/pay/docs/tax-and-invoices)
  - [Bill by usage with meters](https://mishka.tools/pay/docs/usage-billing)
  - [Take payments with PayPal](https://mishka.tools/pay/docs/paypal)
  - [Test code that takes payments](https://mishka.tools/pay/docs/test-your-payments)
  - [Keep payments in Ash resources and Mishka CMS](https://mishka.tools/pay/docs/ash-and-cms)
- **Concepts**: [How Mishka Pay works](https://mishka.tools/pay/docs/how-mishka-pay-works)
- **Reference**: [Capabilities by provider](https://mishka.tools/pay/docs/capabilities),
  [Keys and options](https://mishka.tools/pay/docs/keys-and-options),
  [Errors and telemetry](https://mishka.tools/pay/docs/errors-and-telemetry)

Short guides also ship with the package in `guides/`, and every module has its own docs on
[HexDocs](https://hexdocs.pm/mishka_pay).

## 🛍️ The demo shop

[`examples/shop`](https://github.com/mishka-group/mishka_pay/tree/master/examples/shop) is a
Phoenix shop on your Stripe sandbox that shows every feature. With PayPal sandbox keys it takes
PayPal too. Each part of the page carries a `data-testid` for browser tests.

## 📰 Read more

- [One Elixir API for Stripe and PayPal: Meet Mishka Pay](https://mishka.tools/blog/mishka-pay-elixir-ash-payment-sdk-stripe-paypal-phoenix),
  the announcement post.
- The [Mishka blog](https://mishka.tools/blog), for releases and articles.

## 💬 Community and support

- Chat with the team and other users on [Discord](https://discord.gg/m4zdCJjDJg).
- Report a bug or ask a question in [GitHub issues](https://github.com/mishka-group/mishka_pay/issues).
- For a provider of your own, a payment integration or priority support,
  [hire the Mishka team](https://mishka.tools/hire-us).

## 💖 Support the project

Mishka Pay is free and open source. You can support its development through
[GitHub Sponsors](https://github.com/sponsors/mishka-group) or
[Buy Me a Coffee](https://www.buymeacoffee.com/mishkagroup).

## 📜 License

Apache License 2.0. See [LICENSE](LICENSE).

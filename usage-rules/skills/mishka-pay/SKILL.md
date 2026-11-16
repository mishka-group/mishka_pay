---
name: mishka-pay
description: "Use this skill when a project takes payments with Mishka Pay (`:mishka_pay` in mix.exs, `MishkaPay.checkout`, `MishkaPay.refund`, `MishkaPay.fetch_payment`, `MishkaPay.Webhook`, `MishkaPay.Credentials`, `MishkaPay.Ash.Resource`, `MishkaPay.Errors.*`, `mishka_pay:payment:changed`): adding a checkout or a subscription plan, a refund, a webhook endpoint, per-site payment keys, the Ash payment tables, or tests of payment code."
---

## Overview

Mishka Pay takes payments the same way for every provider. Providers (Stripe; PayPal coming soon)
are mishka_installer plugins; each site's keys come from the host's `MishkaPay.Credentials`
plugin at runtime; every call answers a struct or a `MishkaPay.Errors` error; changes are
announced as mishka_installer events.

## Steps for a payment feature

1. **Keys.** Make sure the project has a keys plugin (`use MishkaPay.Credentials`) answering the
   provider and tenant, and supervises `MishkaPay.Providers.Stripe`.
2. **Checkout.** Call `MishkaPay.checkout/1` with `provider`, `tenant`, `items` (money as
   `%{amount: "19.99", currency: "USD"}`), `success_url` carrying `{CHECKOUT_SESSION_ID}`,
   `cancel_url` and the host's own `reference`. Redirect to `checkout.url`.
3. **Return.** On the success page, `MishkaPay.fetch_checkout/3`, then read the payment or
   subscription itself before giving access.
4. **Webhooks.** `plug MishkaPay.Webhook, at: "/pay/webhooks"` before `Plug.Parsers`; with Ash,
   the inbox and the payment and subscription listeners keep the rows current.
5. **Real time.** A plugin on `mishka_pay:payment:changed` / `mishka_pay:subscription:changed`
   broadcasts on the host's PubSub.
6. **Tests.** `MishkaPay.Test` (`put_keys/3`, `stub_http/1`, `start_plugin!/1`); no live provider.

Done when the checkout, the return page, a refund and the webhook path each have a test, and
access is given from the payment's or subscription's status.

## References

The package's usage rules hold the details: `deps/mishka_pay/usage-rules.md` (calls, errors,
refunds, rules) and `deps/mishka_pay/usage-rules/` (`stripe`, `subscriptions`, `webhooks`, `ash`,
`testing`, `providers`, `paypal`). Read the one for the task before writing code.

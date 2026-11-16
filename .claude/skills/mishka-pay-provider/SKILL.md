---
name: mishka-pay-provider
description: How to add a payment provider (PayPal, Paddle, Adyen, a local gateway...) or a capability to one in mishka_pay, as a mishka_installer plugin on MishkaPay.Provider, end to end: contract, adapter and mapper, shared rules, tests with a stand-in and live sandbox tests, Gettext, and the demo shop. Use it whenever a provider is added or extended, or a provider's checkout, payment, refund, subscription or webhook path changes, even for one callback.
---

# Adding a provider to mishka_pay

A provider is a plugin: one adapter module that `use MishkaPay.Provider`, supervised by the host.
Nothing outside the adapter names it. Stripe (`lib/mishka_pay/providers/stripe.ex`) is the full
reference; PayPal (`lib/mishka_pay/providers/paypal.ex`) shows a provider that works differently
(OAuth tokens, capture after approval, verification by API call). Read both before starting, and
follow the mishka-code-design skill for style.

## 1. Map the provider onto the contract

Write down, before code, how each Mishka Pay idea lands at the provider:

| Mishka Pay | Decide |
|---|---|
| `Checkout` (`mode: :payment` / `:subscription`) | which object is made, where the buyer goes, how they come back (its id in the return URL) |
| `Payment` id | which provider id `fetch_payment` and `refund` take (Stripe: PaymentIntent; PayPal: Order) |
| statuses | the provider's states to `:pending`, `:requires_action`, `:paid`, `:partially_refunded`, `:refunded`, `:failed`, `:canceled` |
| `Credentials` | which of `secret_key`, `publishable_key`, `webhook_secret`, `extra`, `mode` hold its keys |
| idempotency | its header, and which call needs a key (`MishkaPay.ProviderKit.idempotency_key/3`) |
| webhooks | how a message is proven (HMAC, API call, certificate) and which field names the payment or subscription |
| what it cannot do | refused before any request with `Errors.Unsupported` (currencies, modes, price ids) |

Done when every row has an answer. A row with no answer is a capability you leave out of
`capabilities:`, never a callback that half works.

## 2. Write the adapter and its mapper

- `lib/mishka_pay/providers/<id>.ex`: `use MishkaPay.Provider, id:, label:, capabilities:` and one
  callback per capability operation (`MishkaPay.Provider.operations/1`); the compile check refuses
  a missing one. Requests only through `MishkaPay.Client` (retries, idempotency, telemetry).
- `lib/mishka_pay/providers/__<id>/mapper.ex`: pure, structs to request bodies and answers back
  to `MishkaPay.Checkout`, `Payment`, `Refund`, `Subscription`, `Invoice`, `Event`. No requests.
- Shared rules come from `MishkaPay.ProviderKit`: `refund_key/2`, `refundable/3` (the site's
  once/many refund rule), `idempotency_key/3`, `invalid/2`. Never copy them; `mix ex_dna` fails on
  a copy.
- A token the provider makes you fetch goes through `MishkaPay.Helpers.TokenCache` (ETS, no
  process in the path), dropped on a 401.
- An id from a caller is checked by shape before it reaches a path.
- Visible messages go through `MishkaPay.Messages` (new key, `mix gettext.extract --merge`).
- The moduledoc says how a payment goes at this provider, its keys, and what it refuses.

Done when `mix compile --warnings-as-errors` passes and every callback answers the struct or a
`MishkaPay.Errors` error.

## 3. Test it

- A stand-in for the provider's API in `test/support/<id>/<id>_stub.ex`, answering in the
  provider's own shapes, wired with `MishkaPay.Test.stub_http/1`, telling the test each request
  it got (`MishkaPay.Support.PayPalStub` is the pattern). Stripe uses stripe-mock instead.
- `test/mishka_pay/providers/<id>_test.exs`: the request bodies and idempotency headers, every
  status mapping, refusals before any request, the refund rule both ways, webhook proof both ways,
  ids that must never reach a path, a 401 and a decline.
- `test/mishka_pay/providers/<id>_live_test.exs`, tagged `:<id>_live`, excluded in
  `test/test_helper.exs` unless the sandbox keys are set; never a live key.
- Waits are on messages or telemetry, never sleeps (mishka-code-design, testing).

Done when the provider's tests pass with `--repeat-until-failure 10`, and the full gate is clean:
`mix test`, `mix credo --strict`, dialyzer, `mix ex_dna --max-clones 0`,
`mix gettext.extract --check-up-to-date`, `mix format --check-formatted`.

## 4. Put it in the demo shop

`examples/shop` shows every feature of the library, with a `data-testid` on every part:

- supervise the adapter in `lib/shop/application.ex`; answer its keys in `lib/shop/pay/keys.ex`
  from `.env` (add empty slots to `.env`, never real keys in git);
- add it to the checkout's "Pay with" choice, its return handling in `shop_live.ex`, and
  `provider_of/1` for reading ids back;
- give it rows in `mix shop.sandbox` once its sandbox keys are there;
- a README section: how to get sandbox keys and what to try.

Done when a buy, the return, a refund and a read work in the browser on the sandbox, then a Haiku
browser test of the provider's paths passes (Haiku finds, Sonnet verifies, demo bugs fixed by
Sonnet, library bugs by Opus).

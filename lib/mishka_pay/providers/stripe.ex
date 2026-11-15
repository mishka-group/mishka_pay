# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.Stripe do
  @moduledoc """
  Stripe as a provider: `use MishkaPay.Provider, id: "stripe"`. One time payments with Stripe
  Checkout, payments, refunds and the webhook signature.

  Its HTTP calls go through `MishkaPay.Client` with Stripe's base URL, the site's secret key, one
  pinned `Stripe-Version` header and Stripe's form encoding. No third party Stripe library.

  `verify_webhook/3` checks the `Stripe-Signature` header: the HMAC of the raw body with the site's
  webhook secret, compared in constant time, inside the allowed time window.

  Stripe's field names live only in `MishkaPay.Providers.Stripe.Mapper`.

  Stage 2 writes the operations and stage 3 the signature check; tests run against Stripe's test
  mode.
  """
end

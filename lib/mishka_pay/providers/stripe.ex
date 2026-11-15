# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.Stripe do
  @moduledoc """
  Stripe as a provider: `use MishkaPay.Provider, id: "stripe"`. One time payments
  with Stripe Checkout, payments, refunds and the webhook signature.

  It talks to Stripe through its own small client (`MishkaPay.Providers.Stripe.Client`), not a third
  party Stripe library, with one pinned Stripe API version.

  Stage 2 writes it; tests run against Stripe's test mode.
  """
end

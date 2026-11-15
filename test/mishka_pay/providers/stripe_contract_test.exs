# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.StripeContractTest do
  # Stripe passes the same contract every provider does.
  use MishkaPay.ProviderCase, provider: MishkaPay.Providers.Stripe
end

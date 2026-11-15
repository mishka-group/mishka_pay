# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.Stripe.Signature do
  @moduledoc """
  Checks the `Stripe-Signature` header of a webhook: the HMAC of the raw body with the
  site's webhook secret, compared in constant time, inside the allowed time window.

  Stage 3 adds it.
  """
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.Stripe.Mapper do
  @moduledoc """
  Turns Stripe's JSON objects into Mishka Pay's structs (`MishkaPay.Payment`,
  `MishkaPay.Refund`, ...) and Mishka Pay's inputs into Stripe's parameters. The only place that knows
  Stripe's field names.

  Stage 2 adds it.
  """
end

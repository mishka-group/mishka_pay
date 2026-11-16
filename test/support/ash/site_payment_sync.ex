# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.SitePaymentSync do
  @moduledoc "A multi-tenant host's payment sync, each webhook's row in its own site."
  use MishkaPay.Ash.Payment.Listener, resource: MishkaPay.Support.SitePayment
end

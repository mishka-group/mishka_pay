# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.PaymentSync do
  @moduledoc "A host's payment sync, as `MishkaPay.Ash.Payment.Listener` shows it."

  use MishkaPay.Ash.Payment.Listener, resource: MishkaPay.Support.Payment
end

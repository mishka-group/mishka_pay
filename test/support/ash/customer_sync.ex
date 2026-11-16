# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.CustomerSync do
  @moduledoc "A host's customer sync, as `MishkaPay.Ash.Customer.Listener` shows it."

  use MishkaPay.Ash.Customer.Listener, resource: MishkaPay.Support.Customer
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.ProviderCaseTest do
  # One line runs every contract test on a provider, as a project runs it on its own.
  use MishkaPay.ProviderCase, provider: MishkaPay.Support.Acme
end

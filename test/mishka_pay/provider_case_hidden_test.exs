# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.ProviderCaseHiddenTest do
  # A provider kept out of the offered ones still passes: it is installed and listed.
  use MishkaPay.ProviderCase, provider: MishkaPay.Support.Hidden
end

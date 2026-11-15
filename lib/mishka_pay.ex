# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay do
  @moduledoc """
  The calls a project makes to take money: start a checkout, read a payment, refund one.

  Each call names a provider by its id (`"stripe"`), finds it among the installed providers
  (`MishkaPay.Provider.fetch/1`), takes the keys for the site from `MishkaPay.Credentials`, and hands the
  provider a guarded_struct input. The answer is always a guarded_struct or a `MishkaPay.Errors`
  error, the same for every provider.

  This module never names a provider: a project chooses which ones run by supervising their plugins.

  Stage 1 adds the calls.
  """
end

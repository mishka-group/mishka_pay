# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Error do
  @moduledoc """
  The one error every call returns: a reason atom (`:unsupported`,
  `:invalid_input`, `:declined`, `:provider_down`, ...), a short message, and the provider's own answer
  for the log. The same shape for every provider.

  Stage 1 adds the struct.
  """
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors.Unknown do
  @moduledoc """
  The class of errors Mishka Pay does not know: `MishkaPay.Errors.UnknownError` and anything another
  library raised.
  """

  use Splode.ErrorClass, class: :unknown
end

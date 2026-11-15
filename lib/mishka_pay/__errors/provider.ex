# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors.Provider do
  @moduledoc """
  The class of errors a provider gives: it declined, or it cannot do what was asked.
  """

  use Splode.ErrorClass, class: :provider
end

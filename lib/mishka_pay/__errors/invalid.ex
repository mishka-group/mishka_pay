# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors.Invalid do
  @moduledoc """
  The class of errors about wrong input. A guarded_struct validation error lands here too.
  """

  use Splode.ErrorClass, class: :invalid
end

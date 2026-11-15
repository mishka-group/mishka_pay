# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors.UnknownError do
  @moduledoc """
  Any error that is not one of Mishka Pay's own, in the `:unknown` class. `:error` holds what was
  given.
  """

  use Splode.Error, fields: [:error], class: :unknown

  @impl true
  def message(%{error: error}) when is_binary(error), do: error
  def message(%{error: error}), do: inspect(error)
end

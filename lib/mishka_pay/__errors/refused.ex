# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors.Refused do
  @moduledoc """
  Refused by the project itself, before the provider was asked: a plugin on
  `mishka_pay:checkout:before` said no (out of stock, a blocked buyer, a closed shop), or could not
  answer, which counts as no.

    * `:operation`: `:checkout`.
    * `:reason`: the plugin's own words, or why it gave none: `:cannot_run`, `:raised`,
      `:exited`, `:timeout`, `:invalid_answer`.
  """

  use Splode.Error, fields: [:operation, :reason], class: :invalid

  @impl true
  def message(%{operation: operation, reason: reason}) when is_binary(reason),
    do: "the #{operation} was refused: #{reason}"

  def message(%{operation: operation, reason: reason}),
    do: "the #{operation} was refused (#{inspect(reason)})"
end

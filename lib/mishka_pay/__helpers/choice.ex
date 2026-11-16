# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Helpers.Choice do
  @moduledoc false

  # A choice from JSON or a form comes as a string; it becomes the atom the struct's enum checks.
  # Anything else is left for the enum to refuse.
  @spec atom(atom(), term(), [String.t()]) :: {:ok, atom(), term()}
  def atom(field, value, choices) when is_binary(value) do
    case value in choices do
      true -> {:ok, field, String.to_existing_atom(value)}
      false -> {:ok, field, value}
    end
  end

  def atom(field, value, _choices), do: {:ok, field, value}
end

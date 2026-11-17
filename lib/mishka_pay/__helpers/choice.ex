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

  # A list of choices, each an atom or its string, becomes the atoms; one not among `choices` is
  # an error naming them all.
  @spec atoms(atom(), term(), [atom()]) ::
          {:ok, atom(), [atom()] | nil} | {:error, atom(), String.t()}
  def atoms(field, nil, _choices), do: {:ok, field, nil}

  def atoms(field, values, choices) when is_list(values) do
    found =
      Enum.map(values, fn
        value when is_atom(value) or is_binary(value) ->
          Enum.find(choices, &(Atom.to_string(&1) == to_string(value)))

        _other ->
          nil
      end)

    case Enum.all?(found) do
      true -> {:ok, field, Enum.uniq(found)}
      false -> not_a_choice(field, choices)
    end
  end

  def atoms(field, _other, choices), do: not_a_choice(field, choices)

  defp not_a_choice(field, choices),
    do:
      {:error, field,
       MishkaPay.Messages.text(:choices, field: field, choices: Enum.join(choices, ", "))}
end

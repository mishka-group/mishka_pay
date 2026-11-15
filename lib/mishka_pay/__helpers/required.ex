# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Helpers.Required do
  @moduledoc """
  A guarded_struct field validator that refuses `nil`: `validator: {MishkaPay.Helpers.Required, :call}`.

  guarded_struct skips every `derives` op on a field given as `nil`, `not_nil_value` included, and
  `enforce: true` only asks for the key. A validator is called with `nil`, so a required field of a
  Mishka Pay struct uses this one.
  """

  @doc "`{:ok, field, value}`, or an error naming the field when `value` is nil."
  @spec call(atom(), term()) :: {:ok, atom(), term()} | {:error, atom(), String.t()}
  def call(field, nil), do: {:error, field, "The #{field} field is required"}
  def call(field, value), do: {:ok, field, value}
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors.UnknownProvider do
  @moduledoc """
  No offered provider has this id.

    * `:provider`: the id asked for.
    * `:reason`: `:not_installed`, or `:cannot_run` when a plugin of `mishka_pay:providers` is
      registered but not loaded, so no provider can be told installed.
  """

  use Splode.Error, fields: [:provider, :reason], class: :invalid

  @impl true
  def message(%{provider: provider, reason: :cannot_run}),
    do: "payment provider #{provider} cannot be looked up: a provider plugin is not loaded"

  def message(%{provider: provider}), do: "no payment provider #{provider} is installed"
end

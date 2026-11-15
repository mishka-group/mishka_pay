# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors.Unsupported do
  @moduledoc """
  The provider cannot do this operation, as its `capabilities/0` says: a refund through a provider
  without refunds, for example.

    * `:provider`: the provider's id.
    * `:operation`: the operation asked for, such as `:refund`.
  """

  use Splode.Error, fields: [:provider, :operation], class: :provider

  @impl true
  def message(%{provider: provider, operation: operation}),
    do: "#{provider} cannot do #{operation}"
end

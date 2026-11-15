# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors.Unreachable do
  @moduledoc """
  The provider never answered, after every retry: a refused connection, a timeout, a DNS error.

    * `:provider`: the provider's id.
    * `:reason`: the exception Req returned, such as a `Req.TransportError`.
  """

  use Splode.Error, fields: [:provider, :reason], class: :provider

  @impl true
  def message(%{provider: provider, reason: %{__exception__: true} = reason}),
    do: "#{provider} did not answer: #{Exception.message(reason)}"

  def message(%{provider: provider, reason: reason}),
    do: "#{provider} did not answer: #{inspect(reason)}"
end

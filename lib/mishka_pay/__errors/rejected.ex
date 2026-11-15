# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors.Rejected do
  @moduledoc """
  The provider answered with an error that is not a decline: bad keys, a request it did not accept,
  a missing payment, a failure on its side after every retry.

    * `:provider`: the provider's id.
    * `:status`: the HTTP status it answered.
    * `:code`: its own short code, such as `"resource_missing"`, when it gave one.
    * `:message`: its own words, for the log.
  """

  use Splode.Error, fields: [:provider, :status, :code, :message], class: :provider

  @impl true
  def message(%{provider: provider, status: status, code: nil}),
    do: "#{provider} refused the request (HTTP #{status})"

  def message(%{provider: provider, status: status, code: code}),
    do: "#{provider} refused the request: #{code} (HTTP #{status})"
end

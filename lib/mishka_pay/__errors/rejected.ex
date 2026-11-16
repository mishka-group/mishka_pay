# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors.Rejected do
  @moduledoc """
  The provider answered with an error that is not a decline: bad keys, a request it did not accept,
  a missing payment, a failure on its side after every retry.

    * `:provider`: the provider's id.
    * `:status`: the HTTP status it answered.
    * `:code`: its own short code, such as `"resource_missing"`, when it gave one;
      `"idempotency_error"` when a reference was reused with other details.
    * `:message`: its own words, for the log. People see `Exception.message/1` instead, which never
      repeats them (they can name keys and ids).
  """

  alias MishkaPay.Messages

  use Splode.Error, fields: [:provider, :status, :code, :message], class: :provider

  @impl true
  def message(%{code: "idempotency_error"}), do: Messages.text(:reference_reused)

  def message(%{provider: provider, status: status, code: nil}),
    do: Messages.text(:rejected, provider: provider, status: status)

  def message(%{provider: provider, status: status, code: code}),
    do: Messages.text(:rejected_code, provider: provider, code: code, status: status)
end

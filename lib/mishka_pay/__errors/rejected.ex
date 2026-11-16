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
      `"idempotency_error"` when a reference was reused with other details, `"already_exists"`
      when a code or id is taken.
    * `:param`: the field it refused, when it named one: under Mishka Pay's own name when it has
      one (`"trial_days"`, `"quantity_min"`), as the provider said it otherwise.
      `code: "managed_payments_invoice"` is an invoice turned off where the provider, as merchant of
      record, must make one.
    * `:message`: its own words, for the log. People see `Exception.message/1` instead, which never
      repeats them (they can name keys and ids).
  """

  alias MishkaPay.Messages

  use Splode.Error, fields: [:provider, :status, :code, :param, :message], class: :provider

  @impl true
  def message(%{code: "idempotency_error"}), do: Messages.text(:reference_reused)

  def message(%{provider: provider, code: "resource_missing"}),
    do: Messages.text(:rejected_missing, provider: provider)

  def message(%{code: "managed_payments_invoice"}), do: Messages.text(:managed_payments_invoice)

  def message(%{provider: provider, code: "already_exists"}),
    do: Messages.text(:rejected_exists, provider: provider)

  def message(%{provider: provider, status: status, code: nil, param: param})
      when is_binary(param),
      do: Messages.text(:rejected_param, provider: provider, param: param, status: status)

  def message(%{provider: provider, status: status, code: nil}),
    do: Messages.text(:rejected, provider: provider, status: status)

  def message(%{provider: provider, status: status, code: code}),
    do: Messages.text(:rejected_code, provider: provider, code: code, status: status)
end

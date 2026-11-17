# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors.Declined do
  @moduledoc """
  The provider refused the payment or the refund: a declined card, not enough funds, a blocked
  buyer.

    * `:provider`: the provider's id, such as `"stripe"`.
    * `:reason`: the provider's own short code, such as `"card_declined"`.
    * `:answer`: the provider's whole answer, for the log. Never shown to a buyer.
    * `:request_id`: the provider's id of the request (Stripe's `Request-Id` header, PayPal's
      debug id), when it gave one, for its support and the log. Never shown to a buyer.
    * `:doc_url`: the provider's page about the decline, when it named one.
  """

  alias MishkaPay.Messages

  use Splode.Error, fields: [:provider, :reason, :answer, :request_id, :doc_url], class: :provider

  @impl true
  def message(%{provider: provider, reason: nil}),
    do: Messages.text(:declined, provider: provider)

  def message(%{provider: provider, reason: reason}),
    do: Messages.text(:declined_reason, provider: provider, reason: reason)
end

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
  """

  use Splode.Error, fields: [:provider, :reason, :answer], class: :provider

  @impl true
  def message(%{provider: provider, reason: nil}), do: "#{provider} declined the payment"

  def message(%{provider: provider, reason: reason}),
    do: "#{provider} declined the payment: #{reason}"
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.ProviderKit do
  @moduledoc """
  What every provider adapter needs the same way, so each one keeps the same rules: idempotency
  keys from a caller's own ids, the site's refund rule (`MishkaPay.Credentials`, `:refunds`), and
  an `:invalid` error on a field. Stripe and PayPal use it; a provider a project writes can too.
  """

  alias MishkaPay.{Errors, Messages, Payment, Refund}

  @doc """
  The idempotency key of `operation` for `material` (a reference, or anything that names one
  request) and `tenant`: the same inputs always give the same key, so a request sent again is the
  same request at the provider. `nil` material gives `nil`: no key.
  """
  @spec idempotency_key(String.t(), term(), term()) :: String.t() | nil
  def idempotency_key(_operation, _tenant, nil), do: nil

  def idempotency_key(operation, tenant, material) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({tenant, material}))
    "mishka_pay-#{operation}-" <> Base.url_encode64(digest, padding: false)
  end

  @doc """
  The idempotency key of a refund under the site's rule: a site that refunds once has one refund
  per payment, so the payment names it; one that refunds many times names each refund by its
  `:reference`, which it then needs.
  """
  @spec refund_key(Refund.t(), map()) :: {:ok, String.t()} | {:error, Splode.Error.t()}
  def refund_key(refund, %{refunds: :once}),
    do: {:ok, idempotency_key("refund", refund.tenant, refund.payment_id)}

  def refund_key(%Refund{reference: nil}, _many),
    do: invalid(:reference, Messages.text(:refund_reference))

  def refund_key(refund, _many),
    do: {:ok, idempotency_key("refund", refund.tenant, {refund.payment_id, refund.reference})}

  @doc """
  Whether `refund` may go to the provider for `payment` as it is now: refused when the site
  refunds once and the payment has a refund, when nothing is left, or when a part refund is in
  another currency or over what is left.
  """
  @spec refundable(Refund.t(), Payment.t(), map()) :: :ok | {:error, Splode.Error.t()}
  def refundable(%Refund{amount: amount}, %Payment{} = payment, keys) do
    refunded = payment.amount_refunded || Money.new(payment.amount.currency, 0)
    left = Decimal.sub(payment.amount.amount, refunded.amount)

    cond do
      keys.refunds == :once and Money.positive?(refunded) ->
        invalid(:payment_id, Messages.text(:refund_once))

      not Decimal.positive?(left) ->
        invalid(:payment_id, Messages.text(:refund_nothing_left))

      is_nil(amount) ->
        :ok

      amount.currency != payment.amount.currency ->
        invalid(:amount, Messages.text(:refund_currency, currency: payment.amount.currency))

      Decimal.gt?(amount.amount, left) ->
        invalid(:amount, Messages.text(:refund_left))

      true ->
        :ok
    end
  end

  @doc "An `:invalid` class error on `field` with `message`, as a builder error would be."
  @spec invalid(atom(), String.t()) :: {:error, Splode.Error.t()}
  def invalid(field, message),
    do: Errors.from_builder({:error, [%{field: field, action: :provider, message: message}]})
end

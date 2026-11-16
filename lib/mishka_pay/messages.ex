# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Messages do
  @moduledoc """
  Every message a person can see, translated in the locale of the calling process: the errors of
  `MishkaPay.Errors` and the field errors of Mishka Pay's structs. Each is looked up in the
  `mishka_pay` domain of `gettext_backend/0` when it is shown, so a form shows it in its own
  locale.

  `mix gettext.extract` finds every text here; `priv/gettext/mishka_pay.pot` is their template.
  """

  use Gettext, backend: MishkaPay.Gettext

  @typedoc "The name of one message."
  @type key ::
          :bad_signature
          | :money_field
          | :currency_unknown
          | :amount_not_exact
          | :amount_not_number
          | :amount_negative
          | :amount_not_positive
          | :amount_too_large
          | :amount_places
          | :base_url
          | :path_plain
          | :path_root
          | :params_plain
          | :one_body
          | :return_url
          | :metadata_strings
          | :items_empty
          | :items_currency
          | :price_needs
          | :customer_one_of
          | :keys_answer
          | :stripe_id
          | :refund_currency
          | :refund_left
          | :refund_once
          | :refund_reference
          | :stripe_metadata
          | :stripe_three_decimal
          | :declined
          | :declined_reason
          | :missing_keys
          | :missing_keys_reason
          | :refused
          | :rejected
          | :rejected_code
          | :provider_cannot_run
          | :provider_not_installed
          | :unreachable
          | :unsupported

  @doc """
  Returns the Gettext backend in use: the `:gettext_backend` of the `:mishka_pay` application
  config, or `MishkaPay.Gettext`.
  """
  @spec gettext_backend() :: module()
  def gettext_backend, do: Application.get_env(:mishka_pay, :gettext_backend, MishkaPay.Gettext)

  @doc """
  Returns message `key` in the caller's locale, with `bindings` put in its `%{name}` places.

      iex> MishkaPay.Messages.text(:amount_places, currency: "JPY")
      "The amount field has more decimal places than JPY has"
  """
  @spec text(key(), keyword()) :: String.t()
  def text(key, bindings \\ []),
    do: Gettext.dgettext(gettext_backend(), "mishka_pay", msgid(key), bindings)

  defp msgid(:money_field),
    do: dgettext_noop("mishka_pay", "The %{field} field must be money: an amount and a currency")

  defp msgid(:currency_unknown),
    do: dgettext_noop("mishka_pay", "The currency field must be a known ISO 4217 code")

  defp msgid(:amount_not_exact),
    do:
      dgettext_noop(
        "mishka_pay",
        "The amount field must be exact: a Decimal, an integer or a string"
      )

  defp msgid(:amount_not_number),
    do: dgettext_noop("mishka_pay", "The amount field must be a number")

  defp msgid(:amount_negative),
    do: dgettext_noop("mishka_pay", "The amount field must be zero or more")

  defp msgid(:amount_not_positive),
    do: dgettext_noop("mishka_pay", "The amount field must be more than zero")

  defp msgid(:amount_too_large),
    do: dgettext_noop("mishka_pay", "The amount field is too large")

  defp msgid(:amount_places),
    do:
      dgettext_noop("mishka_pay", "The amount field has more decimal places than %{currency} has")

  defp msgid(:base_url),
    do:
      dgettext_noop(
        "mishka_pay",
        "The base_url field must be an http or https address, with no user, query or fragment"
      )

  defp msgid(:path_plain),
    do:
      dgettext_noop(
        "mishka_pay",
        "The path field must be one plain path from the root, with no query, dot segment or encoded slash"
      )

  defp msgid(:path_root),
    do: dgettext_noop("mishka_pay", "The path field must start with /")

  defp msgid(:params_plain),
    do: dgettext_noop("mishka_pay", "The params field must hold plain values only")

  defp msgid(:one_body),
    do: dgettext_noop("mishka_pay", "Send form or json, not both")

  defp msgid(:return_url),
    do: dgettext_noop("mishka_pay", "The %{field} field must be an https address")

  defp msgid(:metadata_strings),
    do: dgettext_noop("mishka_pay", "The metadata field must map string keys to string values")

  defp msgid(:items_empty),
    do: dgettext_noop("mishka_pay", "A checkout needs at least one item")

  defp msgid(:items_currency),
    do: dgettext_noop("mishka_pay", "All items must be in one currency")

  defp msgid(:price_needs),
    do: dgettext_noop("mishka_pay", "A price needs a name and an amount, or a provider id")

  defp msgid(:customer_one_of),
    do: dgettext_noop("mishka_pay", "A customer is an id or an email, one of them")

  defp msgid(:keys_answer),
    do: dgettext_noop("mishka_pay", "A keys plugin must answer a map or nil")

  defp msgid(:stripe_id),
    do: dgettext_noop("mishka_pay", "The payment_id field is not a Stripe id")

  defp msgid(:refund_currency),
    do:
      dgettext_noop(
        "mishka_pay",
        "The amount field must be in the payment's currency, %{currency}"
      )

  defp msgid(:refund_left),
    do:
      dgettext_noop(
        "mishka_pay",
        "The amount field is more than is left to refund on the payment"
      )

  defp msgid(:refund_once),
    do:
      dgettext_noop(
        "mishka_pay",
        "The payment was refunded already: this site refunds a payment once, and a new purchase is a new payment"
      )

  defp msgid(:refund_reference),
    do:
      dgettext_noop(
        "mishka_pay",
        "The reference field is required: this site refunds a payment many times, and each refund needs its own"
      )

  defp msgid(:stripe_metadata),
    do:
      dgettext_noop(
        "mishka_pay",
        "The metadata field is over Stripe's limits: 49 keys of 40 characters, values of 500"
      )

  defp msgid(:stripe_three_decimal),
    do:
      dgettext_noop(
        "mishka_pay",
        "Stripe takes three-decimal currencies only with a last decimal of 0"
      )

  defp msgid(:bad_signature),
    do: dgettext_noop("mishka_pay", "the %{provider} webhook cannot be trusted (%{reason})")

  defp msgid(:declined),
    do: dgettext_noop("mishka_pay", "%{provider} declined the payment")

  defp msgid(:declined_reason),
    do: dgettext_noop("mishka_pay", "%{provider} declined the payment: %{reason}")

  defp msgid(:missing_keys),
    do: dgettext_noop("mishka_pay", "no %{provider} keys for tenant %{tenant}")

  defp msgid(:missing_keys_reason),
    do:
      dgettext_noop(
        "mishka_pay",
        "the %{provider} keys for tenant %{tenant} cannot be read (%{reason})"
      )

  defp msgid(:refused),
    do: dgettext_noop("mishka_pay", "the %{operation} was refused: %{reason}")

  defp msgid(:rejected),
    do: dgettext_noop("mishka_pay", "%{provider} refused the request (HTTP %{status})")

  defp msgid(:rejected_code),
    do: dgettext_noop("mishka_pay", "%{provider} refused the request: %{code} (HTTP %{status})")

  defp msgid(:provider_cannot_run),
    do:
      dgettext_noop(
        "mishka_pay",
        "payment provider %{provider} cannot be looked up: a provider plugin is not loaded"
      )

  defp msgid(:provider_not_installed),
    do: dgettext_noop("mishka_pay", "no payment provider %{provider} is installed")

  defp msgid(:unreachable),
    do: dgettext_noop("mishka_pay", "%{provider} did not answer: %{reason}")

  defp msgid(:unsupported),
    do: dgettext_noop("mishka_pay", "%{provider} cannot do %{operation}")
end

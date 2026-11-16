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
          | :multipart_parts
          | :filename_plain
          | :file_empty
          | :stripe_file_type
          | :stripe_file_size
          | :file_content
          | :return_url
          | :ui_mode_urls
          | :metadata_strings
          | :items_empty
          | :items_currency
          | :items_recurring
          | :items_one_time
          | :trial_mode
          | :price_needs
          | :customer_one_of
          | :customer_needs
          | :reference_reused
          | :percent_off
          | :coupon_one_of
          | :coupon_months
          | :discount_one_of
          | :discounts_or_codes
          | :customer_creation_mode
          | :expires_past
          | :expires_range
          | :plain_id
          | :link_reference
          | :change_nothing
          | :quantity_range
          | :proration_date
          | :managed_payments_invoice
          | :tax_code_missing
          | :one_time_only
          | :recurring_only
          | :rejected_param
          | :change_item
          | :pause_behavior
          | :link_items
          | :invoice_mode
          | :setup_takes_no
          | :setup_currency
          | :currency_setup_only
          | :rejected_missing
          | :rejected_exists
          | :keys_answer
          | :stripe_id
          | :paypal_id
          | :refund_currency
          | :refund_left
          | :capture_over
          | :capture_invoice
          | :refund_once
          | :refund_nothing_left
          | :refund_reference
          | :stripe_metadata
          | :stripe_three_decimal
          | :stripe_whole
          | :meter_interval
          | :usage_value
          | :usage_window
          | :stripe_usage_time
          | :due_sent_only
          | :stripe_event_types
          | :search_needs
          | :fields_three
          | :merchant_of_record_off
          | :dropdown_options
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
    do: dgettext_noop("mishka_pay", "Send one body: form, json or multipart")

  defp msgid(:multipart_parts),
    do:
      dgettext_noop(
        "mishka_pay",
        "The multipart field must be a list of names with bytes, and a filename and content type for a file"
      )

  defp msgid(:filename_plain),
    do:
      dgettext_noop(
        "mishka_pay",
        "The filename field must be a plain name, with no folder or control character"
      )

  defp msgid(:file_empty),
    do: dgettext_noop("mishka_pay", "The content field must hold the file's bytes")

  defp msgid(:stripe_file_type),
    do: dgettext_noop("mishka_pay", "Stripe takes this file only as %{types}")

  defp msgid(:stripe_file_size),
    do: dgettext_noop("mishka_pay", "The file is over Stripe's limit of %{megabytes} MB")

  defp msgid(:file_content),
    do:
      dgettext_noop(
        "mishka_pay",
        "The file's bytes are not the %{content_type} its content_type field names"
      )

  defp msgid(:return_url),
    do: dgettext_noop("mishka_pay", "The %{field} field must be an https address")

  defp msgid(:ui_mode_urls),
    do:
      dgettext_noop(
        "mishka_pay",
        "A hosted checkout needs success_url and cancel_url; an embedded one needs return_url instead"
      )

  defp msgid(:metadata_strings),
    do: dgettext_noop("mishka_pay", "The metadata field must map string keys to string values")

  defp msgid(:items_empty),
    do: dgettext_noop("mishka_pay", "A checkout needs at least one item")

  defp msgid(:items_currency),
    do: dgettext_noop("mishka_pay", "All items must be in one currency")

  defp msgid(:items_recurring),
    do:
      dgettext_noop(
        "mishka_pay",
        "The items field needs a recurring price on every item for a subscription: an interval or a provider price id"
      )

  defp msgid(:items_one_time),
    do:
      dgettext_noop(
        "mishka_pay",
        "The items field has a recurring price: a one-time checkout sells once, use mode subscription"
      )

  defp msgid(:trial_mode),
    do: dgettext_noop("mishka_pay", "The trial_days field needs a subscription checkout")

  defp msgid(:price_needs),
    do: dgettext_noop("mishka_pay", "A price needs a name and an amount, or a provider id")

  defp msgid(:customer_needs),
    do: dgettext_noop("mishka_pay", "The %{field} field is required for this call")

  defp msgid(:percent_off),
    do:
      dgettext_noop("mishka_pay", "The percent off must be a number more than 0 and at most 100")

  defp msgid(:coupon_one_of),
    do: dgettext_noop("mishka_pay", "A coupon takes off a percent or an amount, one of them")

  defp msgid(:coupon_months),
    do:
      dgettext_noop(
        "mishka_pay",
        "The number of months goes with a coupon that repeats, and only with it"
      )

  defp msgid(:discount_one_of),
    do: dgettext_noop("mishka_pay", "A discount names a coupon or a promotion code, one of them")

  defp msgid(:discounts_or_codes),
    do:
      dgettext_noop(
        "mishka_pay",
        "A checkout applies discounts or lets the buyer type a promotion code, not both"
      )

  defp msgid(:customer_creation_mode),
    do:
      dgettext_noop(
        "mishka_pay",
        "Making a customer at checkout works only in a one-time or a setup checkout"
      )

  defp msgid(:expires_past),
    do: dgettext_noop("mishka_pay", "The expiry must be a time still to come")

  defp msgid(:expires_range),
    do:
      dgettext_noop(
        "mishka_pay",
        "The checkout must expire between %{min} minutes and %{max} hours from now"
      )

  defp msgid(:rejected_missing),
    do: dgettext_noop("mishka_pay", "%{provider} has nothing with the id given")

  defp msgid(:rejected_exists),
    do: dgettext_noop("mishka_pay", "%{provider} already has one with that code or id")

  defp msgid(:proration_date),
    do:
      dgettext_noop(
        "mishka_pay",
        "A proration date goes only with prorations, and not with a new billing period starting now"
      )

  defp msgid(:managed_payments_invoice),
    do:
      dgettext_noop(
        "mishka_pay",
        "A merchant of record always makes an invoice: turn merchant of record off to sell without one"
      )

  defp msgid(:tax_code_missing),
    do:
      dgettext_noop(
        "mishka_pay",
        "A merchant of record sells only products with a tax category: give the product one, or turn merchant of record off"
      )

  defp msgid(:one_time_only),
    do:
      dgettext_noop(
        "mishka_pay",
        "%{param} goes only with one-time prices: a plan's subscription makes its own customer and invoices"
      )

  defp msgid(:recurring_only),
    do:
      dgettext_noop(
        "mishka_pay",
        "%{param} goes only with a plan, a price charged on a schedule"
      )

  defp msgid(:quantity_range),
    do: dgettext_noop("mishka_pay", "The smallest quantity must be less than the largest")

  defp msgid(:rejected_param),
    do:
      dgettext_noop(
        "mishka_pay",
        "%{provider} did not accept the value given for %{param}: check it and try again"
      )

  defp msgid(:change_nothing),
    do:
      dgettext_noop(
        "mishka_pay",
        "A subscription change needs a new plan, a new quantity or a new billing period"
      )

  defp msgid(:change_item),
    do:
      dgettext_noop(
        "mishka_pay",
        "This subscription has more than one item: say which one changes"
      )

  defp msgid(:pause_behavior),
    do:
      dgettext_noop(
        "mishka_pay",
        "A pause keeps its invoices as void, keep_as_draft or mark_uncollectible"
      )

  defp msgid(:link_reference),
    do:
      dgettext_noop(
        "mishka_pay",
        "A payment link's reference may hold only letters, digits, underscores and dashes, at most 200"
      )

  defp msgid(:link_items),
    do:
      dgettext_noop(
        "mishka_pay",
        "A payment link sells catalog prices: give at least one, each by its price id"
      )

  defp msgid(:invoice_mode),
    do:
      dgettext_noop(
        "mishka_pay",
        "An invoice is asked for only in a one-time checkout: a subscription makes its own"
      )

  defp msgid(:setup_takes_no),
    do:
      dgettext_noop(
        "mishka_pay",
        "%{param} does not go with a setup checkout: it saves a payment method and charges nothing"
      )

  defp msgid(:setup_currency),
    do:
      dgettext_noop(
        "mishka_pay",
        "A setup checkout needs a currency: it decides which payment methods the page offers"
      )

  defp msgid(:currency_setup_only),
    do:
      dgettext_noop(
        "mishka_pay",
        "The currency field goes only with a setup checkout: a sale takes its currency from its items"
      )

  defp msgid(:plain_id),
    do:
      dgettext_noop(
        "mishka_pay",
        "An id may hold only letters, digits, underscores and dashes"
      )

  defp msgid(:reference_reused),
    do:
      dgettext_noop(
        "mishka_pay",
        "This reference was used in the last 24 hours with other details. Use a new reference, or change the record made then"
      )

  defp msgid(:customer_one_of),
    do: dgettext_noop("mishka_pay", "A customer is an id or an email, one of them")

  defp msgid(:keys_answer),
    do: dgettext_noop("mishka_pay", "A keys plugin must answer a map or nil")

  defp msgid(:stripe_id),
    do:
      dgettext_noop(
        "mishka_pay",
        "The %{field} field is not a Stripe id that starts with %{prefix}"
      )

  defp msgid(:paypal_id),
    do: dgettext_noop("mishka_pay", "The %{field} field is not a PayPal id: letters and digits")

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

  defp msgid(:capture_invoice),
    do:
      dgettext_noop(
        "mishka_pay",
        "Holding the money to capture later does not go with an invoice made at payment, and a merchant of record always makes one: turn both off for this checkout"
      )

  defp msgid(:capture_over),
    do: dgettext_noop("mishka_pay", "The amount field is more than the payment holds")

  defp msgid(:refund_once),
    do:
      dgettext_noop(
        "mishka_pay",
        "This site refunds a payment once, whole or in part, and this payment has its refund already. A new purchase is a new payment."
      )

  defp msgid(:refund_nothing_left),
    do: dgettext_noop("mishka_pay", "The payment is refunded in full: nothing is left to refund")

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
        "The metadata field is over Stripe's limits: 48 keys of 40 characters, values of 500"
      )

  defp msgid(:merchant_of_record_off),
    do:
      dgettext_noop(
        "mishka_pay",
        "%{param} goes only with merchant of record off: set merchant_of_record to false for this checkout"
      )

  defp msgid(:fields_three),
    do: dgettext_noop("mishka_pay", "A checkout asks at most three questions")

  defp msgid(:dropdown_options),
    do:
      dgettext_noop(
        "mishka_pay",
        "A dropdown needs its options, each a value and a label; other fields take none"
      )

  defp msgid(:search_needs),
    do: dgettext_noop("mishka_pay", "Search needs an email, a name or a reference")

  defp msgid(:stripe_event_types),
    do: dgettext_noop("mishka_pay", "Stripe filters events by at most 20 types at a time")

  defp msgid(:meter_interval),
    do: dgettext_noop("mishka_pay", "A price on a meter needs an interval to bill its usage")

  defp msgid(:usage_value),
    do:
      dgettext_noop(
        "mishka_pay",
        "The value field must be an exact number: an integer, a Decimal or a string"
      )

  defp msgid(:usage_window),
    do: dgettext_noop("mishka_pay", "The end of a usage window must come after its start")

  defp msgid(:stripe_usage_time),
    do:
      dgettext_noop(
        "mishka_pay",
        "Stripe takes usage from the last 35 days and up to 5 minutes ahead"
      )

  defp msgid(:due_sent_only),
    do:
      dgettext_noop(
        "mishka_pay",
        "Days to pay go only with a bill that is sent (collection: send_invoice)"
      )

  defp msgid(:stripe_whole),
    do: dgettext_noop("mishka_pay", "Stripe takes %{currency} only in whole units")

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

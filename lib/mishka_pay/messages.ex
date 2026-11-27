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
          | :request_options_none
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
          | :tax_id_invalid
          | :tax_not_set_up
          | :tax_location_invalid
          | :tax_lines_many
          | :tax_lines_unique
          | :tax_address
          | :shipping_needs
          | :shipping_days
          | :managed_payments_shipping
          | :webhook_secrets
          | :account_invalid
          | :connect_not_set_up
          | :connect_v1_customer
          | :customer_v2_email
          | :connect_capability_v1
          | :connect_capability_v2
          | :connect_needs_sandbox
          | :connect_v1_refused
          | :fee_percent
          | :fee_currency
          | :stripe_shipping_five
          | :one_time_only
          | :recurring_only
          | :rejected_param
          | :change_item
          | :pause_behavior
          | :link_items
          | :invoice_mode
          | :setup_takes_no
          | :setup_currency
          | :currency_items
          | :currency_options_once
          | :currency_options_catalog
          | :rejected_missing
          | :rejected_exists
          | :keys_answer
          | :stripe_id
          | :paypal_id
          | :no_upcoming_invoice
          | :paypal_not_approved
          | :paypal_custom_id
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
          | :stripe_usage_digits
          | :tax_calculation_failed
          | :evidence_page_limit
          | :due_sent_only
          | :stripe_event_types
          | :stripe_event_object
          | :usage_stream_live
          | :search_needs
          | :subscription_search_needs
          | :subscription_status
          | :invoice_item_moves
          | :credit_note_one_of
          | :tax_percentage
          | :tax_rate_fixed
          | :tax_rates_line_only
          | :tax_percentage_stripe
          | :tax_rates_automatic
          | :registration_state
          | :registration_scheme
          | :credit_line_needs
          | :phase_prices
          | :phase_length
          | :schedule_from_subscription
          | :proration_discounts_flexible
          | :billing_mode_when_made
          | :schedule_moves
          | :choices
          | :payout_days
          | :delay_days
          | :payout_interval_days
          | :delay_days_most
          | :payment_id_alone
          | :registration_past
          | :return_no_checkout
          | :merchant_of_record_off
          | :portal_feature_off
          | :subscription_of_another
          | :intent_of_invoice
          | :intent_of_checkout
          | :endpoint_url
          | :thin_needs_v2
          | :dropdown_options
          | :declined
          | :declined_reason
          | :missing_keys
          | :missing_keys_reason
          | :refused
          | :rejected
          | :rejected_code
          | :rate_limited
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

  defp msgid(:request_options_none),
    do: dgettext_noop("mishka_pay", "%{provider} takes no api_version or expand option")

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
    do: dgettext_noop("mishka_pay", "Give at least one item")

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

  defp msgid(:tax_id_invalid),
    do:
      dgettext_noop(
        "mishka_pay",
        "The tax id number does not have the form its kind needs: check the number and its country"
      )

  defp msgid(:tax_not_set_up),
    do:
      dgettext_noop(
        "mishka_pay",
        "The provider's tax service is not turned on for this account: set it up in the provider's dashboard first"
      )

  defp msgid(:tax_location_invalid),
    do:
      dgettext_noop(
        "mishka_pay",
        "The buyer's address is not enough to count the tax: give its country, and its postal code in the US"
      )

  defp msgid(:tax_lines_many),
    do: dgettext_noop("mishka_pay", "A tax calculation takes at most 100 lines")

  defp msgid(:tax_lines_unique),
    do: dgettext_noop("mishka_pay", "Each line of a tax calculation needs its own reference")

  defp msgid(:tax_address),
    do:
      dgettext_noop(
        "mishka_pay",
        "A tax calculation needs the buyer's address or a customer whose address the provider keeps"
      )

  defp msgid(:shipping_needs),
    do:
      dgettext_noop(
        "mishka_pay",
        "A shipping rate needs the provider's rate id, or a name and an amount"
      )

  defp msgid(:shipping_days),
    do:
      dgettext_noop(
        "mishka_pay",
        "The fewest days of a delivery estimate must not be more than the most days"
      )

  defp msgid(:webhook_secrets),
    do:
      dgettext_noop(
        "mishka_pay",
        "The webhook_secrets field must be a list of secrets, none of them empty"
      )

  defp msgid(:account_invalid),
    do:
      dgettext_noop(
        "mishka_pay",
        "%{provider} does not know this site's connected account, or the platform's key has no access to it"
      )

  defp msgid(:connect_v1_customer),
    do:
      dgettext_noop(
        "mishka_pay",
        "The configurations field cannot hold customer on Accounts v1: make the account with Accounts v2"
      )

  defp msgid(:customer_v2_email),
    do:
      dgettext_noop(
        "mishka_pay",
        "Accounts v2 lists customers without an email filter: search customers by email, or list them with api v1"
      )

  defp msgid(:connect_capability_v1),
    do:
      dgettext_noop(
        "mishka_pay",
        "The capabilities field takes plain names on Accounts v1, such as transfers"
      )

  defp msgid(:connect_capability_v2),
    do:
      dgettext_noop(
        "mishka_pay",
        "The capabilities field takes each name under its configuration on Accounts v2, such as merchant.card_payments or recipient.stripe_balance.stripe_transfers"
      )

  defp msgid(:connect_needs_sandbox),
    do:
      dgettext_noop(
        "mishka_pay",
        "%{provider} makes this onboarding link only in a sandbox: an account with transfers cannot be onboarded by link in test mode"
      )

  defp msgid(:connect_v1_refused),
    do:
      dgettext_noop(
        "mishka_pay",
        "%{provider} makes new connected accounts on this platform only with Accounts v2: leave connect_api at v2"
      )

  defp msgid(:connect_not_set_up),
    do:
      dgettext_noop(
        "mishka_pay",
        "%{provider} makes connected accounts only once the platform has signed up for Connect in its dashboard"
      )

  defp msgid(:fee_percent),
    do:
      dgettext_noop(
        "mishka_pay",
        "The application_fee_percent field must be a share above 0 and up to 100, with at most two decimals"
      )

  defp msgid(:fee_currency),
    do:
      dgettext_noop(
        "mishka_pay",
        "The application_fee field must be in the same currency as the items"
      )

  defp msgid(:stripe_shipping_five),
    do: dgettext_noop("mishka_pay", "A Stripe checkout offers at most 5 shipping rates")

  defp msgid(:managed_payments_shipping),
    do:
      dgettext_noop(
        "mishka_pay",
        "A merchant of record does not ship goods: turn merchant of record off to charge for shipping"
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

  defp msgid(:currency_items),
    do:
      dgettext_noop(
        "mishka_pay",
        "The currency of a sale must be the currency of every item that carries its own amount"
      )

  defp msgid(:currency_options_once),
    do:
      dgettext_noop(
        "mishka_pay",
        "Give each other currency of a price once, and not the price's own currency"
      )

  defp msgid(:currency_options_catalog),
    do:
      dgettext_noop(
        "mishka_pay",
        "Other currencies belong to a catalog price: a checkout line is charged in the checkout's currency"
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

  defp msgid(:no_upcoming_invoice),
    do:
      dgettext_noop(
        "mishka_pay",
        "The subscription %{id} has no next bill: it is not active, or it ends without one"
      )

  defp msgid(:paypal_not_approved),
    do:
      dgettext_noop(
        "mishka_pay",
        "The buyer has not approved this subscription on PayPal yet, so there is nothing to cancel: it ends by itself"
      )

  defp msgid(:paypal_custom_id),
    do:
      dgettext_noop(
        "mishka_pay",
        "PayPal keeps 127 characters for the reference and the owner together: use shorter ones"
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

  defp msgid(:endpoint_url),
    do:
      dgettext_noop(
        "mishka_pay",
        "The webhook address must be an https URL, such as https://shop.example/pay/webhooks/stripe"
      )

  defp msgid(:thin_needs_v2),
    do:
      dgettext_noop(
        "mishka_pay",
        "Thin events come only through an event destination: use the v2 webhook API, or snapshot events"
      )

  defp msgid(:subscription_of_another),
    do:
      dgettext_noop(
        "mishka_pay",
        "That subscription belongs to another customer: open the portal for the customer who has it"
      )

  defp msgid(:intent_of_invoice),
    do: dgettext_noop("mishka_pay", "This payment belongs to a bill: void the bill instead.")

  defp msgid(:intent_of_checkout),
    do:
      dgettext_noop("mishka_pay", "This payment belongs to a checkout: end the checkout instead.")

  defp msgid(:portal_feature_off),
    do:
      dgettext_noop(
        "mishka_pay",
        "The customer portal has this task turned off: turn it on in the portal's settings at the provider, or use another portal configuration"
      )

  defp msgid(:merchant_of_record_off),
    do:
      dgettext_noop(
        "mishka_pay",
        "%{param} goes only with merchant of record off: set merchant_of_record to false for this checkout"
      )

  defp msgid(:dropdown_options),
    do:
      dgettext_noop(
        "mishka_pay",
        "A dropdown needs its options, each a value and a label; other fields take none"
      )

  defp msgid(:search_needs),
    do: dgettext_noop("mishka_pay", "Search needs an email, a name or a reference")

  defp msgid(:subscription_search_needs),
    do: dgettext_noop("mishka_pay", "Search needs a status, a reference or metadata")

  defp msgid(:choices),
    do: dgettext_noop("mishka_pay", "The %{field} field takes only: %{choices}")

  defp msgid(:payout_days),
    do: dgettext_noop("mishka_pay", "The monthly_days field takes days of the month, 1 to 31")

  defp msgid(:delay_days),
    do: dgettext_noop("mishka_pay", "The delay_days field takes a number of days, or :default")

  defp msgid(:return_no_checkout),
    do: dgettext_noop("mishka_pay", "The return page's query names no checkout of this provider")

  defp msgid(:registration_past),
    do:
      dgettext_noop(
        "mishka_pay",
        "A tax registration starts today or later: leave active_from out to start it now"
      )

  defp msgid(:payment_id_alone),
    do:
      dgettext_noop(
        "mishka_pay",
        "The payment_id filter answers one payment's movements on one page: leave %{field} out"
      )

  defp msgid(:delay_days_most),
    do: dgettext_noop("mishka_pay", "Stripe takes at most %{days} delay days")

  defp msgid(:payout_interval_days),
    do:
      dgettext_noop(
        "mishka_pay",
        "A weekly schedule takes weekly_days and a monthly one monthly_days; no other takes days"
      )

  defp msgid(:tax_percentage),
    do: dgettext_noop("mishka_pay", "The percentage field must be an exact number from 0 to 100")

  defp msgid(:tax_rate_fixed),
    do:
      dgettext_noop(
        "mishka_pay",
        "A tax rate's percentage and inclusive never change: make a new rate and archive this one"
      )

  defp msgid(:tax_percentage_stripe),
    do:
      dgettext_noop(
        "mishka_pay",
        "Stripe takes a seller's own tax as tax rates (tax_rate_ids), not as a line's tax_percentage"
      )

  defp msgid(:tax_rates_line_only),
    do:
      dgettext_noop(
        "mishka_pay",
        "Tax rates go on the lines of a checkout or a bill, not on a catalog price or a payment link"
      )

  defp msgid(:registration_scheme),
    do:
      dgettext_noop(
        "mishka_pay",
        "Stripe takes no such place of supply scheme for this kind of registration in this country"
      )

  defp msgid(:registration_state),
    do:
      dgettext_noop(
        "mishka_pay",
        "A state goes only with a US registration or a Canadian provincial one (province_standard)"
      )

  defp msgid(:tax_rates_automatic),
    do:
      dgettext_noop(
        "mishka_pay",
        "Tax rates set by hand do not go with automatic tax: turn automatic_tax off for this checkout"
      )

  defp msgid(:credit_note_one_of),
    do: dgettext_noop("mishka_pay", "A credit note takes an amount or lines, one of them")

  defp msgid(:credit_line_needs),
    do:
      dgettext_noop(
        "mishka_pay",
        "A credit note line names a line of the bill with a quantity or an amount, or a name with the credit for one"
      )

  defp msgid(:phase_prices),
    do: dgettext_noop("mishka_pay", "A phase charges one or more catalog prices, each by its id")

  defp msgid(:phase_length),
    do:
      dgettext_noop(
        "mishka_pay",
        "A phase lasts a number of periods of one interval, or until an end date, one of them"
      )

  defp msgid(:proration_discounts_flexible),
    do:
      dgettext_noop(
        "mishka_pay",
        "Proration discounts go only with the flexible billing mode: leave them out, or use billing_mode flexible"
      )

  defp msgid(:billing_mode_when_made),
    do:
      dgettext_noop(
        "mishka_pay",
        "The billing mode is set when a subscription is made: a running one keeps its own"
      )

  defp msgid(:schedule_from_subscription),
    do:
      dgettext_noop(
        "mishka_pay",
        "A schedule made from a subscription takes its plan from it: change its phases after it is made"
      )

  defp msgid(:schedule_moves),
    do: dgettext_noop("mishka_pay", "A schedule stays on its customer and subscription")

  defp msgid(:invoice_item_moves),
    do:
      dgettext_noop(
        "mishka_pay",
        "An invoice item stays on its customer and bill: delete it and add a new one instead"
      )

  defp msgid(:subscription_status),
    do: dgettext_noop("mishka_pay", "The status field must be one of: %{statuses}")

  defp msgid(:stripe_event_types),
    do: dgettext_noop("mishka_pay", "Stripe filters events by at most 20 types at a time")

  defp msgid(:usage_stream_live),
    do:
      dgettext_noop(
        "mishka_pay",
        "Stripe counts high-volume usage in live mode only: in a sandbox or test mode, report it without stream"
      )

  defp msgid(:stripe_event_object),
    do:
      dgettext_noop(
        "mishka_pay",
        "Only thin events are listed by the object they are about; read them with events: :thin"
      )

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

  defp msgid(:stripe_usage_digits),
    do:
      dgettext_noop(
        "mishka_pay",
        "Stripe takes a usage value of at most %{digits} digits, %{places} of them after the decimal point: round it first"
      )

  defp msgid(:tax_calculation_failed),
    do:
      dgettext_noop(
        "mishka_pay",
        "The provider could not count the tax for this sale: try again, and ask the provider's support if it keeps failing"
      )

  defp msgid(:evidence_page_limit),
    do:
      dgettext_noop(
        "mishka_pay",
        "The evidence is longer than the card network takes for this dispute: shorten the text or send files with fewer pages"
      )

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

  defp msgid(:rate_limited),
    do:
      dgettext_noop(
        "mishka_pay",
        "%{provider} is limiting how fast this site may ask: try again in a moment"
      )

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
    do: dgettext_noop("mishka_pay", "%{provider} does not support %{operation}")
end

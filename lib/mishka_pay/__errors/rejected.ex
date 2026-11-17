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
      record, must make one; `"tax_code_missing"` a product it sells as merchant of record without
      a tax category; `"merchant_of_record_off"` a choice (`:param`) the provider takes only with
      merchant of record off; `"one_time_only"` and `"recurring_only"` a choice (`:param`) that
      goes only with one-time prices, or only with a plan's; `"capture_invoice"` a checkout that
      holds the money (`capture: :manual`) where an invoice is made after payment, as a merchant
      of record always makes one; `"tax_id_invalid"` a tax id whose number
      does not have the form its kind needs; `"tax_not_set_up"` a tax calculation on an account
      whose tax service is off; `"tax_location_invalid"` a buyer's address too thin to count the
      tax; `"managed_payments_shipping"` shipping asked of a checkout the provider sells as
      merchant of record; `"portal_feature_off"` a portal task the portal's settings turn off;
      `"subscription_of_another"` a subscription that belongs to another customer;
      `"intent_of_invoice"` and `"intent_of_checkout"` a PaymentIntent an invoice or a checkout
      made, which only its invoice (voided) or its checkout (expired) can end;
      `"account_invalid"` a connected account (the keys' `:account_id`) the key has no access to,
      or that does not exist; `"connect_not_set_up"` a connected account asked of a platform that
      has not signed up for Connect.
    * `:message`: its own words, for the log. People see `Exception.message/1` instead, which never
      repeats them (they can name keys and ids).
    * `:request_id`: the provider's id of the request that failed (Stripe's `Request-Id` header,
      PayPal's debug id), when it gave one. Quote it to the provider's support, or find the request
      in its dashboard log.
    * `:doc_url`: the provider's page about the error, when it named one.
    * `:rate_limit_reason`: why the provider limited the rate of a request it answered 429 for,
      when it said (Stripe's `Stripe-Rate-Limited-Reason`: `"global-rate"`, `"endpoint-rate"`,
      `"global-concurrency"`, `"endpoint-concurrency"`, `"resource-specific"`). Its message
      then says to try again in a moment.

  The request id and the page are for support and the log only: `Exception.message/1` never shows
  them.
  """

  alias MishkaPay.Messages

  use Splode.Error,
    fields: [
      :provider,
      :status,
      :code,
      :param,
      :message,
      :request_id,
      :doc_url,
      :rate_limit_reason
    ],
    class: :provider

  @impl true
  def message(%{code: "idempotency_error"}), do: Messages.text(:reference_reused)

  def message(%{provider: provider, code: "resource_missing"}),
    do: Messages.text(:rejected_missing, provider: MishkaPay.Provider.label_of(provider))

  def message(%{provider: provider, status: 429}),
    do: Messages.text(:rate_limited, provider: MishkaPay.Provider.label_of(provider))

  def message(%{code: "managed_payments_invoice"}), do: Messages.text(:managed_payments_invoice)
  def message(%{code: "tax_code_missing"}), do: Messages.text(:tax_code_missing)
  def message(%{code: "portal_feature_off"}), do: Messages.text(:portal_feature_off)
  def message(%{code: "subscription_of_another"}), do: Messages.text(:subscription_of_another)
  def message(%{code: "capture_invoice"}), do: Messages.text(:capture_invoice)
  def message(%{code: "intent_of_invoice"}), do: Messages.text(:intent_of_invoice)
  def message(%{code: "intent_of_checkout"}), do: Messages.text(:intent_of_checkout)

  def message(%{code: "merchant_of_record_off", param: param}),
    do: Messages.text(:merchant_of_record_off, param: param || "this choice")

  def message(%{provider: provider, code: "account_invalid"}),
    do: Messages.text(:account_invalid, provider: MishkaPay.Provider.label_of(provider))

  def message(%{provider: provider, code: "connect_not_set_up"}),
    do: Messages.text(:connect_not_set_up, provider: MishkaPay.Provider.label_of(provider))

  def message(%{code: "tax_id_invalid"}), do: Messages.text(:tax_id_invalid)
  def message(%{code: "tax_not_set_up"}), do: Messages.text(:tax_not_set_up)

  def message(%{code: "managed_payments_shipping"}),
    do: Messages.text(:managed_payments_shipping)

  def message(%{code: "tax_location_invalid"}), do: Messages.text(:tax_location_invalid)

  def message(%{code: "one_time_only", param: param}),
    do: Messages.text(:one_time_only, param: param || "this choice")

  def message(%{code: "recurring_only", param: param}),
    do: Messages.text(:recurring_only, param: param || "this choice")

  def message(%{provider: provider, code: "already_exists"}),
    do: Messages.text(:rejected_exists, provider: MishkaPay.Provider.label_of(provider))

  def message(%{provider: provider, code: nil, param: param}) when is_binary(param),
    do:
      Messages.text(:rejected_param,
        provider: MishkaPay.Provider.label_of(provider),
        param: param
      )

  def message(%{provider: provider, status: status, code: nil}),
    do: Messages.text(:rejected, provider: MishkaPay.Provider.label_of(provider), status: status)

  def message(%{provider: provider, status: status, code: code}),
    do:
      Messages.text(:rejected_code,
        provider: MishkaPay.Provider.label_of(provider),
        code: code,
        status: status
      )
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.Stripe do
  @moduledoc """
  Stripe as a provider: one time payments with Stripe Checkout, reading a payment and refunds.

  Supervise it to install it, and answer its keys for each tenant (`MishkaPay.Credentials`); only
  `secret_key` is needed here, `webhook_secret` joins with webhooks.

      children = [MishkaPay.Providers.Stripe]

  It talks to Stripe through `MishkaPay.Client` (retries, one idempotency key per call,
  telemetry), with the tenant's secret key and one pinned Stripe API version,
  `2026-10-28.endive`, so a change of the account's default version never changes what this
  module reads. No third party Stripe library is used. Stripe's field names live only in
  `MishkaPay.Providers.Stripe.Mapper`.

    * `checkout/2` opens a Checkout Session in `payment` mode and answers its page. A price's
      `:tax_code` is its product tax code, and `:merchant_of_record` (the checkout's, else the
      tenant's setting in `MishkaPay.Credentials`) turns Stripe Managed Payments on or off for the
      session; an account with Managed Payments on by default needs a tax code
      on every price. The caller's
      `:reference` goes to Stripe as `client_reference_id` and as metadata on the session and its
      payment, and it makes the idempotency key, so the same reference never opens two sessions.
    * `fetch_checkout/2` reads a Checkout Session back, with the PaymentIntent it made.
    * `fetch_payment/2` reads a PaymentIntent with its latest charge, the charge's refunds and the
      customer, in one request: the buyer, the card, the receipt, why it failed and every refund.
    * `fetch_subscription/2`, `cancel_subscription/3`, `resume_subscription/2` and
      `list_invoices/2` read a Subscription with its customer and products, cancel it at once
      (`DELETE`) or at the period's end (`cancel_at_period_end`), take that back, and list its
      Invoices. A checkout in `mode: :subscription` starts one, with its trial and the reference
      on the subscription. `list_subscriptions/2` lists them by customer, price or status (Stripe
      leaves canceled ones out unless asked for them or for `:all`), and `search_subscriptions/2`
      finds them with Stripe's search by status, reference or metadata.
    * `create_subscription_schedule/2`, `fetch_subscription_schedule/2`,
      `list_subscription_schedules/2`, `update_subscription_schedule/2`,
      `release_subscription_schedule/2` and `cancel_subscription_schedule/3` use Subscription
      Schedules (`sub_sched_...`): made `from_subscription`, or for a customer with phases; a
      phase's `:iterations` and `:interval` are its `duration` (this API version has no
      `iterations`), and the reference makes the idempotency key and is kept in its metadata
      (set in a second request on one made from a subscription, which Stripe makes without
      metadata).
    * `create_customer/2`, `fetch_customer/2`, `update_customer/2`, `list_customers/2` and
      `delete_customer/2` keep Customers (`cus_...`), with the reference in their metadata; a
      delete is for good and cancels the customer's subscriptions at once; `create_tax_id/2`,
      `list_tax_ids/2` and `delete_tax_id/3` keep a customer's tax ids (`txi_...`);
      `portal_session/2` opens a
      billing portal session for one, with the portal configuration (`bpc_...`) it names;
      `create_portal_configuration/2`, `update_portal_configuration/2`,
      `fetch_portal_configuration/2` and `list_portal_configurations/2` keep those (Stripe never
      deletes one: `active: false` turns it off). Stripe answers a portal session only once the account's
      portal is set up (Settings, Billing, Customer portal), in test mode too.
    * A checkout in `mode: :setup` opens a session in Stripe's `setup` mode that saves a card
      without a charge, with Managed Payments off (Stripe takes no setup mode with it) and, without
      a known customer, `customer_creation: always`. `list_payment_methods/2`,
      `fetch_payment_method/2`, `detach_payment_method/2` and `set_default_payment_method/3` keep
      a customer's PaymentMethods (`pm_...`); the default is the customer's
      `invoice_settings.default_payment_method`.
    * `create_shipping_rate/2` and `list_shipping_rates/2` keep Shipping Rates (`shr_...`). A
      checkout's `:shipping_countries` is `shipping_address_collection` and its `:shipping_rates`
      are `shipping_options` (a rate by id, or `shipping_rate_data`), up to 5, in payment mode
      only. Stripe refuses shipping where Managed Payments is on.
    * `calculate_tax/2` asks Stripe Tax for the tax on a sale made outside Checkout
      (`POST /v1/tax/calculations`), and `record_tax/3` records it as a Tax Transaction
      (`create_from_calculation`) under the caller's reference, which makes its idempotency key.
      An account without Stripe Tax turned on is refused with code `"tax_not_set_up"`.
    * `create_invoice_item/2`, `update_invoice_item/2`, `delete_invoice_item/2` and
      `list_invoice_items/2` keep Invoice Items (`ii_...`) on their own: a charge that waits for
      the customer's next invoice, or goes on a draft one; the reference makes the idempotency
      key and is kept in the item's metadata.
    * `create_credit_note/2`, `preview_credit_note/2`, `fetch_credit_note/2`,
      `void_credit_note/2`, `list_credit_notes/2` and `list_credit_note_lines/3` use Credit
      Notes (`cn_...`) on finalized invoices: by `amount` or by line (an invoice line `il_...`
      or a custom one), with `refund_amount`, `credit_amount` and `out_of_band_amount`; the
      reference makes the idempotency key and is kept in the note's metadata. A note's lines
      carry no currency, so its lines are read with the note first.
    * `refund/2` refunds a PaymentIntent, in full or in part, once or many times as the tenant
      allows (`MishkaPay.Refund`).
    * `upload_file/2` sends a file to `files.stripe.com` as `multipart/form-data`; dispute
      evidence only as PDF, JPEG or PNG, up to 5 MB, and its bytes must be the type it names.
      `fetch_file/2` reads one, and `file_link/3` makes a FileLink, a public address of it.
      `update_dispute/2` takes only a file id (`file_...`) in the evidence fields that hold a
      file, such as `receipt` and `uncategorized_file`.
    * `create_meter/2`, `fetch_meter/2`, `update_meter/2` (its display name only),
      `list_meters/2`, `deactivate_meter/2`, `reactivate_meter/2`, `report_usage/2`,
      `cancel_usage/2` and `usage_summary/3` use Billing Meters (`mtr_...`) and meter events,
      Stripe's basic usage billing; a price with `:meter_id` is a metered price on one. A
      report's reference makes its `identifier`; Stripe takes reports from the last 35 days and
      up to 5 minutes ahead, and counts summaries from and to whole minutes. A cancel is a meter
      event adjustment (`type: cancel`) of one identifier, within 24 hours of the report; the
      identifier makes its idempotency key.
    * `create_feature/2`, `attach_feature/3` and `list_entitlements/2` use Entitlements: features
      (`feat_...`) on products, and the active entitlements of a customer.
    * `fetch_fraud_warning/2` and `list_fraud_warnings/2` read Radar's early fraud warnings
      (`issfr_...`), by PaymentIntent or charge; `list_fraud_reviews/2` lists the open Reviews
      (`prv_...`) Radar's rules placed, `fetch_fraud_review/2` reads one and
      `approve_fraud_review/2` approves it. Stripe sends `radar.early_fraud_warning.*` and
      `review.opened`/`review.closed` about them.
    * `fetch_balance/1` reads the payments balance, and `list_balance_transactions/2` its
      balance transactions (`txn_...`), by payout (`po_...`) or type.
    * `adjust_customer_balance/2` and `list_customer_balance/2` keep a customer's credit balance
      (`cbtxn_...`): below zero is credit.
    * `raw_request/2` calls any path of `api.stripe.com` with the tenant's key, the pinned
      version or the call's own `api_version` (`Stripe-Version`) and its `expand[]`, and answers
      Stripe's JSON as it is; a write's reference, with its method and path, makes the
      idempotency key.

    * `verify_webhook/3` checks the `Stripe-Signature` header: an HMAC-SHA256 of
      `"<timestamp>.<raw body>"` with the tenant's `webhook_secret`, or any of its
      `webhook_secrets` while a rolled secret runs out, compared in constant time with every
      `v1` signature in it, signed within the last five minutes
      (`config :mishka_pay, MishkaPay.Providers.Stripe, webhook_tolerance: seconds`), and from the
      same mode (live or test) as the tenant's keys.

  A tenant whose keys name a connected account (`:account_id`, `acct_...`) acts as that account:
  every request carries it in the `Stripe-Account` header, and only from the keys. Such a tenant
  takes only webhook messages about its own account (Stripe's `account` on the event); one about
  the platform or another connected account is refused like a bad signature. Keys without one
  are the platform's own, and take its connected accounts' events, each with its `:account`.

  Stripe answers 402 for a declined card (`MishkaPay.Errors.Declined`, with Stripe's decline code)
  and other errors as `MishkaPay.Errors.Rejected` with its code and status. Both keep Stripe's
  `Request-Id` header as `:request_id` (`req_...`) and its error page as `:doc_url`, for support and
  the log; their messages never show them.

  Stripe counts a few currencies differently from ISO 4217: ISK and UGX as two-decimal amounts
  ending in 00, and MGA as zero-decimal. Mishka Pay sends and reads them as Stripe counts them,
  and refuses a fraction of one before any request. HUF and TWD charge with two decimals like
  other currencies (Stripe pays them out in whole units). It takes BHD, JOD, KWD, OMR and TND only with a last decimal of 0, and metadata up to 48 keys of 40
  characters with values of 500; anything past that is an `:invalid` error before any request.

  A refund first reads the payment. A tenant that refunds once is refused a second refund, and a
  part refund in another currency than the payment's, or over what is left, is refused, since
  Stripe counts a refund in the payment's own currency.

  `config :mishka_pay, MishkaPay.Providers.Stripe, base_url: "http://localhost:12111"` points it at
  another address, such as Stripe's own mock server in tests. Uploads go to `files_url` when it is
  set, else to `base_url` when that is set, else to `https://files.stripe.com`.
  """

  use MishkaPay.Provider,
    id: "stripe",
    label: "Stripe",
    capabilities: [
      :checkout,
      :embedded_checkout,
      :capture,
      :payment_list,
      :catalog,
      :payment_link,
      :dispute,
      :fraud,
      :file,
      :expire,
      :refund,
      :refund_read,
      :subscription,
      :subscription_change,
      :subscription_list,
      :subscription_schedule,
      :invoice,
      :invoice_item,
      :credit_note,
      :customer,
      :tax_id,
      :tax,
      :shipping,
      :portal,
      :payment_method,
      :discount,
      :usage,
      :entitlement,
      :balance,
      :customer_balance,
      :raw_request,
      :webhook,
      :event_list
    ]

  alias MishkaPay.{
    Checkout,
    Client,
    Coupon,
    CreditNote,
    Customer,
    Errors,
    InvoiceItem,
    Messages,
    Page,
    PaymentLink,
    PortalConfiguration,
    Price,
    Product,
    PromotionCode,
    ProviderKit,
    Refund,
    RequestOptions,
    SubscriptionSchedule
  }

  alias MishkaPay.Providers.Stripe.Mapper

  @version "2026-10-28.endive"
  @reference "mishka_pay_reference"
  @base_url "https://api.stripe.com"
  @files_url "https://files.stripe.com"

  # What Stripe takes for each purpose of a file: its most bytes and its types, with the first
  # bytes of each type (docs.stripe.com/file-upload).
  @file_rules %{
    dispute_evidence:
      {5_000_000,
       %{
         "application/pdf" => "%PDF-",
         "image/jpeg" => <<0xFF, 0xD8, 0xFF>>,
         "image/png" => <<0x89, "PNG">>
       }}
  }
  @three_decimal ~w(BHD JOD KWD OMR TND)a

  @handled %{
    "checkout.session.completed" => [:payment, :subscription],
    "checkout.session.expired" => [:payment],
    "checkout.session.async_payment_succeeded" => [:payment],
    "checkout.session.async_payment_failed" => [:payment],
    "payment_intent.succeeded" => [:payment],
    "payment_intent.payment_failed" => [:payment],
    "payment_intent.canceled" => [:payment],
    "payment_intent.processing" => [:payment],
    "payment_intent.requires_action" => [:payment],
    "payment_intent.amount_capturable_updated" => [:payment],
    "charge.succeeded" => [:payment],
    "charge.failed" => [:payment],
    "charge.refunded" => [:payment],
    "charge.captured" => [:payment],
    "charge.expired" => [:payment],
    "refund.created" => [:payment],
    "refund.updated" => [:payment],
    "refund.failed" => [:payment],
    "charge.dispute.created" => [:payment, :dispute],
    "charge.dispute.updated" => [:payment, :dispute],
    "charge.dispute.closed" => [:payment, :dispute],
    "charge.dispute.funds_withdrawn" => [:payment, :dispute],
    "charge.dispute.funds_reinstated" => [:payment, :dispute],
    "invoice.paid" => [:subscription, :invoice],
    "invoice.payment_failed" => [:subscription, :invoice],
    "invoice.finalized" => [:subscription, :invoice],
    "invoice.payment_action_required" => [:subscription, :invoice],
    "invoice.voided" => [:subscription, :invoice],
    "invoice.marked_uncollectible" => [:subscription, :invoice],
    "invoice.overdue" => [:subscription, :invoice],
    "invoice.upcoming" => [:subscription],
    "invoice_payment.paid" => [:payment],
    "customer.subscription.created" => [:subscription],
    "customer.subscription.updated" => [:subscription],
    "customer.subscription.deleted" => [:subscription],
    "customer.subscription.paused" => [:subscription],
    "customer.subscription.resumed" => [:subscription],
    "customer.subscription.trial_will_end" => [:subscription],
    "invoice.created" => [:invoice],
    "invoice.updated" => [:invoice],
    "invoice.sent" => [:invoice],
    "invoice.deleted" => [:invoice],
    "subscription_schedule.created" => [:subscription_schedule, :subscription],
    "subscription_schedule.updated" => [:subscription_schedule, :subscription],
    "subscription_schedule.released" => [:subscription_schedule, :subscription],
    "subscription_schedule.canceled" => [:subscription_schedule, :subscription],
    "subscription_schedule.completed" => [:subscription_schedule, :subscription],
    "subscription_schedule.aborted" => [:subscription_schedule, :subscription],
    "subscription_schedule.expiring" => [:subscription_schedule, :subscription],
    "credit_note.created" => [:credit_note],
    "credit_note.updated" => [:credit_note],
    "credit_note.voided" => [:credit_note],
    "radar.early_fraud_warning.created" => [:fraud_warning, :payment],
    "radar.early_fraud_warning.updated" => [:fraud_warning, :payment],
    "review.opened" => [:fraud_review, :payment],
    "review.closed" => [:fraud_review, :payment],
    "product.created" => [:product],
    "product.updated" => [:product],
    "product.deleted" => [:product],
    "price.created" => [:price],
    "price.updated" => [:price],
    "price.deleted" => [:price],
    "coupon.created" => [:coupon],
    "coupon.updated" => [:coupon],
    "coupon.deleted" => [:coupon],
    "promotion_code.created" => [:promotion_code],
    "promotion_code.updated" => [:promotion_code],
    "payment_link.created" => [:payment_link],
    "payment_link.updated" => [:payment_link],
    "customer.created" => [:customer],
    "customer.updated" => [:customer],
    "customer.deleted" => [:customer],
    "setup_intent.succeeded" => [:customer],
    "setup_intent.setup_failed" => [:customer],
    "payment_method.attached" => [:customer],
    "payment_method.detached" => [:customer],
    "payment_method.updated" => [:customer],
    "payment_method.automatically_updated" => [:customer],
    "entitlements.active_entitlement_summary.updated" => [:customer],
    "customer.tax_id.created" => [:customer],
    "customer.tax_id.updated" => [:customer],
    "customer.tax_id.deleted" => [:customer]
  }

  @doc """
  The Stripe events that change what Mishka Pay keeps, each with what it updates: `:payment`
  (a resource with `mishka_pay do kind :payment end`), `:subscription`, `:customer`, `:dispute`,
  `:invoice`, `:product`, `:price`, `:coupon`, `:promotion_code` or `:payment_link`; or the
  provider object it is about (`:credit_note`; `:subscription_schedule`, which names its
  subscription too; `:fraud_warning` and `:fraud_review`, which name their payment too). Each is mapped to its
  ids (`MishkaPay.Event`) and tested; any other event is still verified and stored, and changes
  nothing. Send these to the webhook endpoint in the Stripe Dashboard.
  """
  @spec handled_events() :: %{String.t() => [atom()]}
  def handled_events, do: @handled

  @doc "The Stripe API version every request is pinned to."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  The API version of Stripe's newest published OpenAPI spec (github.com/stripe/openapi): its
  `info.version`, the first value in Stripe's version form (`2026-10-28.endive`) in the file's
  first bytes. `mix mishka_pay.stripe.check_version` compares it with `version/0`.
  """
  @spec latest_version() :: {:ok, String.t()} | {:error, Splode.Error.t()}
  def latest_version do
    with {:ok, %Req.Response{status: status, body: head}} when status in [200, 206] <-
           Client.request(%{
             provider: "stripe",
             method: :get,
             base_url: "https://raw.githubusercontent.com",
             path: "/stripe/openapi/master/latest/openapi.spec3.json",
             headers: %{"range" => "bytes=0-4095"},
             options: [decode_body: false]
           }),
         [_head, version] <- Regex.run(~r/"version"\s*:\s*"(\d{4}-\d{2}-\d{2}\.[a-z]+)"/, head) do
      {:ok, version}
    else
      {:error, _unreachable} = error -> error
      _other -> {:error, Errors.Rejected.exception(provider: "stripe", code: "spec_unreadable")}
    end
  end

  @impl MishkaPay.Provider
  def checkout(%Checkout{} = checkout, keys) do
    with :ok <- currencies(checkout.items),
         :ok <- metadata(checkout.metadata),
         :ok <- suffix_fits(checkout, keys),
         :ok <- expiry(checkout.expires_at),
         :ok <- held(checkout, keys),
         :ok <- shipping_rates(checkout.shipping_rates),
         {:ok, session} <-
           request(:post, "/v1/checkout/sessions", Mapper.checkout_params(checkout, keys), keys,
             key: ProviderKit.idempotency_key("checkout", checkout.tenant, checkout.reference)
           ) do
      {:ok, Mapper.checkout(session, checkout)}
    end
  end

  # Stripe refuses to hold the money where it makes an invoice after payment: with `invoice: true`,
  # or as the merchant of record (Managed Payments), which always makes one. An account whose
  # default is Managed Payments is refused by Stripe itself (`capture_invoice`).
  defp held(%Checkout{capture: :manual} = checkout, keys) do
    case checkout.invoice == true or Mapper.merchant_of_record(checkout, keys) == true do
      true -> invalid(:capture, Messages.text(:capture_invoice))
      false -> :ok
    end
  end

  defp held(_checkout, _keys), do: :ok

  @impl MishkaPay.Provider
  def fetch_checkout(checkout_id, keys) do
    with :ok <- stripe_id(checkout_id, "cs_", :checkout_id),
         {:ok, session} <-
           request(
             :get,
             "/v1/checkout/sessions/#{checkout_id}",
             [{"expand[]", "line_items"}, {"expand[]", "setup_intent"}],
             keys
           ) do
      {:ok, Mapper.checkout(session)}
    end
  end

  @impl MishkaPay.Provider
  def expire_checkout(checkout_id, keys) do
    with :ok <- stripe_id(checkout_id, "cs_", :checkout_id),
         {:ok, session} <-
           request(:post, "/v1/checkout/sessions/#{checkout_id}/expire", %{}, keys) do
      {:ok, Mapper.checkout(session)}
    end
  end

  @impl MishkaPay.Provider
  def fetch_payment(payment_id, keys) do
    with {:ok, payment} <- read_payment(payment_id, keys),
         {:ok, sessions} <-
           request(
             :get,
             "/v1/checkout/sessions",
             [
               {"payment_intent", payment_id},
               {"limit", "1"},
               {"expand[]", "data.line_items"}
             ],
             keys
           ) do
      {:ok,
       Mapper.with_checkout(payment, sessions |> Map.get("data") |> List.wrap() |> List.first())}
    end
  end

  # The PaymentIntent alone, with its charge, refunds and customer: what a refund checks against.
  defp read_payment(payment_id, keys) do
    with :ok <- stripe_id(payment_id, "pi_", :payment_id),
         {:ok, intent} <-
           request(:get, "/v1/payment_intents/#{payment_id}", payment_expand(), keys) do
      Mapper.payment(intent)
    end
  end

  defp payment_expand,
    do: [
      {"expand[]", "latest_charge"},
      {"expand[]", "latest_charge.refunds"},
      {"expand[]", "customer"}
    ]

  # A part is checked against the payment first: Stripe reads `amount_to_capture` in the
  # payment's own currency, so money in another one would be taken as the wrong sum.
  @impl MishkaPay.Provider
  def capture_payment(payment_id, opts, keys) do
    amount = opts[:amount]

    with :ok <- stripe_id(payment_id, "pi_", :payment_id),
         :ok <- capturable(payment_id, amount, keys),
         {:ok, intent} <-
           request(
             :post,
             "/v1/payment_intents/#{payment_id}/capture",
             form(Mapper.capture_params(amount)) ++ payment_expand(),
             keys,
             key:
               ProviderKit.idempotency_key(
                 "capture",
                 keys.tenant,
                 {payment_id, amount && Mapper.minor(amount)}
               )
           ) do
      Mapper.payment(intent)
    end
  end

  defp capturable(_payment_id, nil, _keys), do: :ok

  defp capturable(payment_id, amount, keys) do
    with :ok <- currencies([%{amount: amount}]),
         {:ok, payment} <- read_payment(payment_id, keys) do
      cond do
        amount.currency != payment.amount.currency ->
          invalid(:amount, Messages.text(:refund_currency, currency: payment.amount.currency))

        Decimal.gt?(amount.amount, payment.amount.amount) ->
          invalid(:amount, Messages.text(:capture_over))

        true ->
          :ok
      end
    end
  end

  @impl MishkaPay.Provider
  def cancel_payment(payment_id, keys) do
    with :ok <- stripe_id(payment_id, "pi_", :payment_id),
         {:ok, intent} <-
           request(:post, "/v1/payment_intents/#{payment_id}/cancel", payment_expand(), keys,
             key: ProviderKit.idempotency_key("payment-cancel", keys.tenant, payment_id)
           ) do
      Mapper.payment(intent)
    end
  end

  @impl MishkaPay.Provider
  def refund(%Refund{} = refund, keys) do
    with :ok <- stripe_id(refund.payment_id, "pi_", :payment_id),
         :ok <- currencies([refund]),
         {:ok, key} <- ProviderKit.refund_key(refund, keys),
         {:ok, payment} <- read_payment(refund.payment_id, keys),
         :ok <- ProviderKit.refundable(refund, payment, keys),
         {:ok, answer} <-
           request(:post, "/v1/refunds", Mapper.refund_params(refund), keys, key: key) do
      Mapper.refund(answer, refund)
    end
  end

  @impl MishkaPay.Provider
  def fetch_refund(refund_id, keys) do
    with :ok <- refund_id(refund_id),
         {:ok, refund} <- request(:get, "/v1/refunds/#{refund_id}", [], keys) do
      Mapper.refund(refund)
    end
  end

  @impl MishkaPay.Provider
  def list_refunds(opts, keys) do
    with :ok <- maybe_id(opts[:payment_id], "pi_", :payment_id) do
      page("/v1/refunds", [payment_intent: opts[:payment_id]], opts, keys, &Mapper.refund/1)
    end
  end

  # Stripe's refund ids start with `re_`, and `pyr_` for some payment methods.
  defp refund_id("pyr_" <> _ = id), do: stripe_id(id, "pyr_", :refund_id)
  defp refund_id(id), do: stripe_id(id, "re_", :refund_id)

  @impl MishkaPay.Provider
  def fetch_subscription(subscription_id, keys) do
    with :ok <- stripe_id(subscription_id, "sub_", :subscription_id),
         {:ok, sub} <-
           request(:get, "/v1/subscriptions/#{subscription_id}", subscription_expand(), keys) do
      Mapper.subscription(sub)
    end
  end

  # Now ends it at once; at the period's end it runs until the period paid for is over, and can
  # still be taken back.
  @impl MishkaPay.Provider
  def cancel_subscription(subscription_id, :now, keys) do
    with :ok <- stripe_id(subscription_id, "sub_", :subscription_id),
         {:ok, _canceled} <- request(:delete, "/v1/subscriptions/#{subscription_id}", %{}, keys) do
      fetch_subscription(subscription_id, keys)
    end
  end

  def cancel_subscription(subscription_id, :period_end, keys),
    do: cancel_at_period_end(subscription_id, true, keys)

  @impl MishkaPay.Provider
  def resume_subscription(subscription_id, keys),
    do: cancel_at_period_end(subscription_id, false, keys)

  @impl MishkaPay.Provider
  def list_invoices(opts, keys) do
    with :ok <- maybe_id(opts[:subscription_id], "sub_", :subscription_id),
         :ok <- maybe_id(opts[:customer_id], "cus_", :customer_id) do
      filters = [subscription: opts[:subscription_id], customer: opts[:customer_id]]
      page("/v1/invoices", filters, opts, keys, &Mapper.invoice/1)
    end
  end

  # A listed subscription brings its customer. Stripe expands four levels at most, so its prices'
  # products are not: an item has its `:product_id`, and the price's nickname as its name.
  @impl MishkaPay.Provider
  def list_subscriptions(opts, keys) do
    with :ok <- maybe_id(opts[:customer_id], "cus_", :customer_id),
         :ok <- maybe_id(opts[:price_id], "price_", :price_id) do
      filters = [
        customer: opts[:customer_id],
        price: opts[:price_id],
        status: opts[:status],
        "expand[]": "data.customer"
      ]

      page("/v1/subscriptions", filters, opts, keys, &Mapper.subscription/1)
    end
  end

  # A schedule's reference makes the idempotency key, so a retry never makes two. Stripe takes no
  # metadata with `from_subscription`: a schedule made so gets its reference and metadata in a
  # second request.
  @impl MishkaPay.Provider
  def create_subscription_schedule(%SubscriptionSchedule{} = schedule, keys) do
    with :ok <- maybe_id(schedule.subscription_id, "sub_", :subscription_id),
         :ok <- maybe_id(schedule.customer_id, "cus_", :customer_id),
         :ok <- schedule_fits(schedule),
         {:ok, answer} <-
           request(
             :post,
             "/v1/subscription_schedules",
             Mapper.subscription_schedule_params(schedule),
             keys,
             key:
               ProviderKit.idempotency_key(
                 "subscription-schedule",
                 schedule.tenant,
                 schedule.reference
               )
           ) do
      labelled(answer, schedule, keys)
    end
  end

  defp labelled(answer, %SubscriptionSchedule{subscription_id: from} = schedule, keys)
       when is_binary(from) do
    labels = %SubscriptionSchedule{
      provider: "stripe",
      metadata: schedule.metadata,
      reference: schedule.reference
    }

    case Mapper.subscription_schedule_update_params(labels) do
      none when map_size(none) == 0 -> Mapper.subscription_schedule(answer)
      params -> schedule_call(:post, answer["id"], "", params, keys)
    end
  end

  defp labelled(answer, _schedule, _keys), do: Mapper.subscription_schedule(answer)

  @impl MishkaPay.Provider
  def fetch_subscription_schedule(schedule_id, keys),
    do: schedule_call(:get, schedule_id, "", [], keys)

  @impl MishkaPay.Provider
  def list_subscription_schedules(opts, keys) do
    with :ok <- maybe_id(opts[:customer_id], "cus_", :customer_id) do
      filters = [customer: opts[:customer_id], scheduled: opts[:scheduled]]
      page("/v1/subscription_schedules", filters, opts, keys, &Mapper.subscription_schedule/1)
    end
  end

  @impl MishkaPay.Provider
  def update_subscription_schedule(%SubscriptionSchedule{id: id} = schedule, keys) do
    with :ok <- schedule_fits(schedule) do
      schedule_call(:post, id, "", Mapper.subscription_schedule_update_params(schedule), keys)
    end
  end

  @impl MishkaPay.Provider
  def release_subscription_schedule(schedule_id, keys),
    do: schedule_call(:post, schedule_id, "/release", %{}, keys)

  @impl MishkaPay.Provider
  def cancel_subscription_schedule(schedule_id, opts, keys) do
    params = %{"invoice_now" => opts[:invoice_now], "prorate" => opts[:prorate]}
    schedule_call(:post, schedule_id, "/cancel", params, keys)
  end

  defp schedule_call(method, schedule_id, step, params, keys) do
    with :ok <- stripe_id(schedule_id, "sub_sched_", :schedule_id),
         {:ok, answer} <-
           request(method, "/v1/subscription_schedules/#{schedule_id}#{step}", params, keys) do
      Mapper.subscription_schedule(answer)
    end
  end

  # Phases charge Stripe prices, and the metadata is what Stripe keeps.
  defp schedule_fits(schedule) do
    with :ok <-
           all_fine(schedule.phases || [], fn phase ->
             all_fine(phase.items || [], &stripe_id(&1.id, "price_", :phases))
           end),
         do: metadata(schedule.metadata)
  end

  @impl MishkaPay.Provider
  def list_payments(opts, keys) do
    with :ok <- maybe_id(opts[:customer_id], "cus_", :customer_id) do
      filters = [
        customer: opts[:customer_id],
        "expand[]": "data.latest_charge",
        "expand[]": "data.latest_charge.refunds",
        "expand[]": "data.customer"
      ]

      page("/v1/payment_intents", filters, opts, keys, &Mapper.payment/1)
    end
  end

  # Every mapped item, or the first one that failed.
  defp all_ok(results) do
    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, item} -> item end)}
      error -> error
    end
  end

  @impl MishkaPay.Provider
  def fetch_invoice(invoice_id, keys) do
    with :ok <- stripe_id(invoice_id, "in_", :invoice_id),
         {:ok, invoice} <- request(:get, "/v1/invoices/#{invoice_id}", [], keys) do
      Mapper.invoice(invoice)
    end
  end

  # A draft bill, then each item on it; a draft left half made is deleted, so a retry with the
  # same reference starts clean.
  @impl MishkaPay.Provider
  def create_invoice(%MishkaPay.InvoiceDraft{} = draft, keys) do
    with :ok <- stripe_id(draft.customer_id, "cus_", :customer_id),
         :ok <- invoice_prices(draft.items),
         :ok <- currencies(draft.items),
         :ok <- metadata(draft.metadata),
         {:ok, %{"id" => invoice_id}} <-
           request(:post, "/v1/invoices", Mapper.invoice_params(draft), keys,
             key: ProviderKit.idempotency_key("invoice", draft.tenant, draft.reference)
           ) do
      case add_items(draft, invoice_id, keys) do
        :ok ->
          fetch_invoice(invoice_id, keys)

        {:error, _refused} = error ->
          _deleted = request(:delete, "/v1/invoices/#{invoice_id}", [], keys)
          error
      end
    end
  end

  # A catalog item is sold by a Stripe price id.
  defp invoice_prices(items) do
    case Enum.find(items, &(is_binary(&1.id) and not stripe_price?(&1.id))) do
      nil -> :ok
      %{id: id} -> stripe_id(id, "price_", :items)
    end
  end

  defp add_items(draft, invoice_id, keys) do
    draft.items
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      params = Mapper.invoice_item_params(item, invoice_id, draft.customer_id)

      case request(:post, "/v1/invoiceitems", params, keys,
             key: ProviderKit.idempotency_key("invoice-item", draft.tenant, {invoice_id, index})
           ) do
        {:ok, _item} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @impl MishkaPay.Provider
  def finalize_invoice(invoice_id, keys),
    do: invoice_step(invoice_id, "finalize", %{"auto_advance" => false}, keys)

  @impl MishkaPay.Provider
  def send_invoice(invoice_id, keys), do: invoice_step(invoice_id, "send", %{}, keys)

  @impl MishkaPay.Provider
  def pay_invoice(invoice_id, opts, keys) do
    params =
      case Keyword.get(opts, :out_of_band, false) do
        true -> %{"paid_out_of_band" => true}
        false -> %{}
      end

    invoice_step(invoice_id, "pay", params, keys)
  end

  @impl MishkaPay.Provider
  def void_invoice(invoice_id, keys), do: invoice_step(invoice_id, "void", %{}, keys)

  @impl MishkaPay.Provider
  def mark_invoice_uncollectible(invoice_id, keys),
    do: invoice_step(invoice_id, "mark_uncollectible", %{}, keys)

  @impl MishkaPay.Provider
  def delete_invoice(invoice_id, keys) do
    with :ok <- stripe_id(invoice_id, "in_", :invoice_id),
         {:ok, _deleted} <- request(:delete, "/v1/invoices/#{invoice_id}", [], keys),
         do: :ok
  end

  # An item kept on its own; its reference makes the idempotency key, so a retry never charges
  # twice.
  @impl MishkaPay.Provider
  def create_invoice_item(%InvoiceItem{} = item, keys) do
    with :ok <- stripe_id(item.customer_id, "cus_", :customer_id),
         :ok <- maybe_id(item.invoice_id, "in_", :invoice_id),
         :ok <- item_fits(item),
         {:ok, answer} <-
           request(:post, "/v1/invoiceitems", Mapper.invoice_item_params(item), keys,
             key: ProviderKit.idempotency_key("invoice-item-own", item.tenant, item.reference)
           ) do
      Mapper.invoice_item(answer)
    end
  end

  @impl MishkaPay.Provider
  def update_invoice_item(%InvoiceItem{id: id} = item, keys) do
    with :ok <- stripe_id(id, "ii_", :id),
         :ok <- item_fits(item),
         {:ok, answer} <-
           request(:post, "/v1/invoiceitems/#{id}", Mapper.invoice_item_update_params(item), keys) do
      Mapper.invoice_item(answer)
    end
  end

  @impl MishkaPay.Provider
  def delete_invoice_item(invoice_item_id, keys) do
    with :ok <- stripe_id(invoice_item_id, "ii_", :invoice_item_id),
         {:ok, _deleted} <- request(:delete, "/v1/invoiceitems/#{invoice_item_id}", [], keys),
         do: :ok
  end

  @impl MishkaPay.Provider
  def list_invoice_items(opts, keys) do
    with :ok <- maybe_id(opts[:customer_id], "cus_", :customer_id),
         :ok <- maybe_id(opts[:invoice_id], "in_", :invoice_id) do
      filters = [
        customer: opts[:customer_id],
        invoice: opts[:invoice_id],
        pending: opts[:pending]
      ]

      page("/v1/invoiceitems", filters, opts, keys, &Mapper.invoice_item/1)
    end
  end

  # A credit note's reference makes the idempotency key, so a retry never credits twice.
  @impl MishkaPay.Provider
  def create_credit_note(%CreditNote{} = note, keys) do
    with :ok <- note_fits(note),
         {:ok, answer} <-
           request(:post, "/v1/credit_notes", Mapper.credit_note_params(note), keys,
             key: ProviderKit.idempotency_key("credit-note", note.tenant, note.reference)
           ) do
      Mapper.credit_note(answer)
    end
  end

  @impl MishkaPay.Provider
  def preview_credit_note(%CreditNote{} = note, keys) do
    with :ok <- note_fits(note),
         {:ok, answer} <-
           request(:get, "/v1/credit_notes/preview", Mapper.credit_note_params(note), keys) do
      Mapper.credit_note(answer)
    end
  end

  @impl MishkaPay.Provider
  def fetch_credit_note(credit_note_id, keys) do
    with :ok <- stripe_id(credit_note_id, "cn_", :credit_note_id),
         {:ok, answer} <- request(:get, "/v1/credit_notes/#{credit_note_id}", [], keys) do
      Mapper.credit_note(answer)
    end
  end

  @impl MishkaPay.Provider
  def void_credit_note(credit_note_id, keys) do
    with :ok <- stripe_id(credit_note_id, "cn_", :credit_note_id),
         {:ok, answer} <- request(:post, "/v1/credit_notes/#{credit_note_id}/void", %{}, keys) do
      Mapper.credit_note(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_credit_notes(opts, keys) do
    with :ok <- maybe_id(opts[:invoice_id], "in_", :invoice_id),
         :ok <- maybe_id(opts[:customer_id], "cus_", :customer_id) do
      filters = [invoice: opts[:invoice_id], customer: opts[:customer_id]]
      page("/v1/credit_notes", filters, opts, keys, &Mapper.credit_note/1)
    end
  end

  # Stripe's line items carry no currency: the note gives it.
  @impl MishkaPay.Provider
  def list_credit_note_lines(credit_note_id, opts, keys) do
    with :ok <- stripe_id(credit_note_id, "cn_", :credit_note_id),
         {:ok, %{"currency" => currency}} <-
           request(:get, "/v1/credit_notes/#{credit_note_id}", [], keys) do
      page(
        "/v1/credit_notes/#{credit_note_id}/lines",
        [],
        opts,
        keys,
        &Mapper.credit_note_line(&1, currency)
      )
    end
  end

  # A finalized bill by its Stripe id, invoice lines by theirs, amounts Stripe counts, metadata it
  # keeps.
  defp note_fits(note) do
    lines = note.lines || []
    money = [note.amount, note.refund_amount, note.credit_amount, note.out_of_band_amount]

    with :ok <- stripe_id(note.invoice_id, "in_", :invoice_id),
         :ok <- all_fine(lines, &maybe_id(&1.invoice_line_id, "il_", :lines)),
         :ok <-
           money
           |> Kernel.++(Enum.flat_map(lines, &[&1.amount, &1.unit_amount]))
           |> Enum.map(&%{amount: &1})
           |> currencies(),
         do: metadata(note.metadata)
  end

  # A catalog price by its Stripe id, an amount in a currency Stripe counts, metadata it keeps.
  defp item_fits(item) do
    with :ok <- maybe_id(item.price_id, "price_", :price_id),
         :ok <- currencies([item]),
         do: metadata(item.metadata)
  end

  defp invoice_step(invoice_id, step, params, keys) do
    with :ok <- stripe_id(invoice_id, "in_", :invoice_id),
         {:ok, invoice} <- request(:post, "/v1/invoices/#{invoice_id}/#{step}", params, keys) do
      Mapper.invoice(invoice)
    end
  end

  @impl MishkaPay.Provider
  def change_subscription(change, keys) do
    with {:ok, item_id} <- item_of(change, keys),
         {:ok, _changed} <-
           request(
             :post,
             "/v1/subscriptions/#{change.subscription_id}",
             Mapper.change_params(change, item_id),
             keys
           ) do
      fetch_subscription(change.subscription_id, keys)
    end
  end

  @impl MishkaPay.Provider
  def preview_subscription_change(change, keys) do
    with {:ok, item_id} <- item_of(change, keys),
         {:ok, invoice} <-
           request(
             :post,
             "/v1/invoices/create_preview",
             Mapper.preview_params(change, item_id),
             keys
           ) do
      Mapper.invoice(invoice)
    end
  end

  @impl MishkaPay.Provider
  def pause_collection(subscription_id, opts, keys) do
    pause = %{
      "behavior" => Atom.to_string(opts[:behavior]),
      "resumes_at" => opts[:resumes_at] && DateTime.to_unix(opts[:resumes_at])
    }

    with :ok <- stripe_id(subscription_id, "sub_", :subscription_id),
         {:ok, _paused} <-
           request(
             :post,
             "/v1/subscriptions/#{subscription_id}",
             %{"pause_collection" => pause},
             keys
           ) do
      fetch_subscription(subscription_id, keys)
    end
  end

  # Stripe takes an empty `pause_collection` as "collect again".
  @impl MishkaPay.Provider
  def resume_collection(subscription_id, keys) do
    with :ok <- stripe_id(subscription_id, "sub_", :subscription_id),
         {:ok, _resumed} <-
           request(
             :post,
             "/v1/subscriptions/#{subscription_id}",
             %{"pause_collection" => ""},
             keys
           ) do
      fetch_subscription(subscription_id, keys)
    end
  end

  # The item a change names, or the subscription's only one; one of several must be named.
  defp item_of(%{item_id: item_id} = change, _keys) when is_binary(item_id) do
    with :ok <- stripe_id(change.subscription_id, "sub_", :subscription_id),
         :ok <- stripe_id(item_id, "si_", :item_id),
         :ok <- maybe_id(change.price_id, "price_", :price_id),
         do: {:ok, item_id}
  end

  defp item_of(change, keys) do
    with :ok <- maybe_id(change.price_id, "price_", :price_id),
         {:ok, subscription} <- fetch_subscription(change.subscription_id, keys) do
      case subscription.items do
        [%{item_id: item_id}] when is_binary(item_id) -> {:ok, item_id}
        _many_or_none -> ProviderKit.invalid(:item_id, Messages.text(:change_item))
      end
    end
  end

  defp cancel_at_period_end(subscription_id, cancel?, keys) do
    with :ok <- stripe_id(subscription_id, "sub_", :subscription_id),
         {:ok, _updated} <-
           request(
             :post,
             "/v1/subscriptions/#{subscription_id}",
             %{"cancel_at_period_end" => to_string(cancel?)},
             keys
           ) do
      fetch_subscription(subscription_id, keys)
    end
  end

  defp subscription_expand,
    do: [{"expand[]", "customer"}, {"expand[]", "items.data.price.product"}]

  @impl MishkaPay.Provider
  def create_customer(%Customer{} = customer, keys) do
    with :ok <- metadata(customer.metadata),
         {:ok, answer} <-
           request(:post, "/v1/customers", Mapper.customer_params(customer), keys,
             key: ProviderKit.idempotency_key("customer", customer.tenant, customer.reference)
           ) do
      Mapper.customer(answer)
    end
  end

  @impl MishkaPay.Provider
  def fetch_customer(customer_id, keys) do
    with :ok <- stripe_id(customer_id, "cus_", :customer_id),
         {:ok, answer} <- request(:get, "/v1/customers/#{customer_id}", [], keys) do
      Mapper.customer(answer)
    end
  end

  @impl MishkaPay.Provider
  def update_customer(%Customer{id: id} = customer, keys) do
    with :ok <- stripe_id(id, "cus_", :id),
         :ok <- metadata(customer.metadata),
         {:ok, answer} <-
           request(:post, "/v1/customers/#{id}", Mapper.customer_params(customer), keys) do
      Mapper.customer(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_customers(opts, keys),
    do: page("/v1/customers", [email: opts[:email]], opts, keys, &Mapper.customer/1)

  # Stripe deletes for good and cancels the customer's subscriptions at once; a read after answers
  # it with `deleted: true` (`customer_deleted`).
  @impl MishkaPay.Provider
  def delete_customer(customer_id, keys) do
    with :ok <- stripe_id(customer_id, "cus_", :customer_id),
         {:ok, _deleted} <- request(:delete, "/v1/customers/#{customer_id}", [], keys),
         do: :ok
  end

  # A tax id has no reference of its own, so it goes without a fixed idempotency key: the same
  # number added again after a delete must make a new one.
  @impl MishkaPay.Provider
  def create_tax_id(%MishkaPay.TaxId{customer_id: customer_id} = tax_id, keys) do
    with :ok <- stripe_id(customer_id, "cus_", :customer_id),
         {:ok, answer} <-
           request(
             :post,
             "/v1/customers/#{customer_id}/tax_ids",
             Mapper.tax_id_params(tax_id),
             keys
           ) do
      Mapper.tax_id(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_tax_ids(opts, keys) do
    with :ok <- stripe_id(opts[:customer_id], "cus_", :customer_id) do
      page("/v1/customers/#{opts[:customer_id]}/tax_ids", [], opts, keys, &Mapper.tax_id/1)
    end
  end

  # Stripe Tax on its own: a calculation (`taxcalc_...`) changes nothing until it is recorded as a
  # Tax Transaction under the caller's reference.
  @impl MishkaPay.Provider
  def calculate_tax(%MishkaPay.TaxCalculation{} = calculation, keys) do
    shipping = (calculation.shipping && [%{amount: calculation.shipping}]) || []

    with :ok <- maybe_id(calculation.customer_id, "cus_", :customer_id),
         :ok <- currencies(calculation.items ++ shipping),
         {:ok, answer} <-
           request(
             :post,
             "/v1/tax/calculations",
             Mapper.tax_calculation_params(calculation),
             keys
           ) do
      Mapper.tax_calculation(answer)
    end
  end

  @impl MishkaPay.Provider
  def record_tax(calculation_id, reference, keys) do
    with :ok <- stripe_id(calculation_id, "taxcalc_", :calculation_id),
         {:ok, answer} <-
           request(
             :post,
             "/v1/tax/transactions/create_from_calculation",
             %{"calculation" => calculation_id, "reference" => reference},
             keys,
             key: ProviderKit.idempotency_key("tax-record", keys.tenant, reference)
           ) do
      Mapper.tax_transaction(answer, calculation_id)
    end
  end

  @impl MishkaPay.Provider
  def create_shipping_rate(%MishkaPay.ShippingRate{} = rate, keys) do
    with :ok <- currencies([rate]),
         :ok <- metadata(rate.metadata),
         {:ok, answer} <-
           request(:post, "/v1/shipping_rates", Mapper.shipping_rate_params(rate), keys) do
      Mapper.shipping_rate(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_shipping_rates(opts, keys),
    do: page("/v1/shipping_rates", [active: opts[:active]], opts, keys, &Mapper.shipping_rate/1)

  # Stripe offers up to 5 rates on a checkout: its own by id (`shr_`), or new ones in a currency
  # it takes.
  defp shipping_rates(nil), do: :ok

  defp shipping_rates(rates) do
    case Enum.drop(rates, 5) do
      [] -> with :ok <- currencies(rates), do: shipping_rate_ids(rates)
      _more -> invalid(:shipping_rates, Messages.text(:stripe_shipping_five))
    end
  end

  defp shipping_rate_ids(rates) do
    case Enum.find(rates, &(is_binary(&1.id) and not shipping_rate?(&1.id))) do
      nil -> :ok
      %{id: id} -> stripe_id(id, "shr_", :shipping_rates)
    end
  end

  @impl MishkaPay.Provider
  def delete_tax_id(customer_id, tax_id_id, keys) do
    with :ok <- stripe_id(customer_id, "cus_", :customer_id),
         :ok <- stripe_id(tax_id_id, "txi_", :tax_id_id),
         {:ok, _deleted} <-
           request(:delete, "/v1/customers/#{customer_id}/tax_ids/#{tax_id_id}", [], keys),
         do: :ok
  end

  # Stripe's search language: each filter quoted, a quote inside escaped; the reference is kept
  # in the customer's metadata.
  @impl MishkaPay.Provider
  def search_customers(opts, keys) do
    [
      {"email", opts[:email]},
      {"name", opts[:name]},
      {"metadata['#{@reference}']", opts[:reference]}
    ]
    |> search("/v1/customers/search", :search_needs, opts, keys, &Mapper.customer/1)
  end

  # The reference and the caller's metadata are both in the subscription's metadata.
  @impl MishkaPay.Provider
  def search_subscriptions(opts, keys) do
    metadata =
      for {key, value} <- Map.new(opts[:metadata] || []),
          do: {"metadata['#{quoted(key)}']", value}

    [
      {"status", opts[:status] && Atom.to_string(opts[:status])},
      {"metadata['#{@reference}']", opts[:reference]} | metadata
    ]
    |> search(
      "/v1/subscriptions/search",
      :subscription_search_needs,
      opts,
      keys,
      &Mapper.subscription/1,
      "expand[]": "data.customer"
    )
  end

  # One page of a Stripe search: every filter given, joined with AND. Search pages on its own
  # `next_page` cursor.
  defp search(filters, path, needs, opts, keys, map, expand \\ []) do
    case for {field, value} <- filters, is_binary(value), do: "#{field}:'#{quoted(value)}'" do
      [] ->
        invalid(:query, Messages.text(needs))

      clauses ->
        params =
          [query: Enum.join(clauses, " AND "), limit: opts[:limit], page: opts[:after]]
          |> Kernel.++(expand)
          |> Enum.reject(fn {_name, value} -> is_nil(value) end)
          |> Enum.map(fn {name, value} -> {Atom.to_string(name), to_string(value)} end)

        with {:ok, %{"data" => data} = answer} <- request(:get, path, params, keys),
             {:ok, items} <- data |> Enum.map(map) |> all_ok() do
          next = answer["has_more"] == true && answer["next_page"]
          {:ok, struct(Page, items: items, has_more: is_binary(next), next: next || nil)}
        end
    end
  end

  defp quoted(text), do: String.replace(to_string(text), ~S('), ~S(\'))

  @impl MishkaPay.Provider
  def upcoming_invoice(subscription_id, keys) do
    with :ok <- stripe_id(subscription_id, "sub_", :subscription_id),
         {:ok, invoice} <-
           request(
             :post,
             "/v1/invoices/create_preview",
             %{"subscription" => subscription_id},
             keys
           ) do
      Mapper.invoice(invoice)
    end
  end

  @impl MishkaPay.Provider
  def portal_session(%MishkaPay.PortalSession{} = session, keys) do
    with :ok <- stripe_id(session.customer_id, "cus_", :customer_id),
         :ok <- maybe_id(session.subscription_id, "sub_", :subscription_id),
         :ok <- maybe_id(session.configuration, "bpc_", :configuration),
         {:ok, answer} <-
           request(
             :post,
             "/v1/billing_portal/sessions",
             %{
               "customer" => session.customer_id,
               "return_url" => session.return_url,
               "configuration" => session.configuration,
               "flow_data" => Mapper.portal_flow(session)
             },
             keys
           ) do
      {:ok, %{session | id: answer["id"], url: answer["url"]}}
    end
  end

  @impl MishkaPay.Provider
  def create_portal_configuration(%PortalConfiguration{} = config, keys),
    do: save_portal_configuration("/v1/billing_portal/configurations", config, keys)

  @impl MishkaPay.Provider
  def update_portal_configuration(%PortalConfiguration{id: id} = config, keys) do
    with :ok <- stripe_id(id, "bpc_", :id),
         do: save_portal_configuration("/v1/billing_portal/configurations/#{id}", config, keys)
  end

  @impl MishkaPay.Provider
  def fetch_portal_configuration(configuration_id, keys) do
    with :ok <- stripe_id(configuration_id, "bpc_", :configuration_id),
         {:ok, answer} <-
           request(
             :get,
             "/v1/billing_portal/configurations/#{configuration_id}",
             [{"expand[]", "features.subscription_update.products"}],
             keys
           ) do
      Mapper.portal_configuration(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_portal_configurations(opts, keys) do
    filters = [
      active: opts[:active],
      is_default: opts[:default],
      "expand[]": "data.features.subscription_update.products"
    ]

    page("/v1/billing_portal/configurations", filters, opts, keys, &Mapper.portal_configuration/1)
  end

  # A plan's product is a catalog id (Stripe's own, or one the host chose) and its prices Stripe's.
  # Stripe answers a configuration's plans only when they are expanded.
  defp save_portal_configuration(path, config, keys) do
    plans = config.plans || []

    with :ok <- metadata(config.metadata),
         :ok <- all_fine(plans, &plain_id(&1.product_id, :plans)),
         :ok <- all_fine(Enum.flat_map(plans, & &1.price_ids), &stripe_id(&1, "price_", :plans)),
         {:ok, answer} <-
           request(
             :post,
             path,
             Map.put(
               Mapper.portal_configuration_params(config),
               "expand",
               ["features.subscription_update.products"]
             ),
             keys
           ) do
      Mapper.portal_configuration(answer)
    end
  end

  defp all_fine(items, check),
    do: Enum.find_value(items, :ok, &with(:ok <- check.(&1), do: nil))

  @impl MishkaPay.Provider
  def list_payment_methods(opts, keys) do
    customer_id = opts[:customer_id]

    with :ok <- stripe_id(customer_id, "cus_", :customer_id) do
      page(
        "/v1/customers/#{customer_id}/payment_methods",
        [],
        opts,
        keys,
        &Mapper.payment_method/1
      )
    end
  end

  @impl MishkaPay.Provider
  def fetch_payment_method(payment_method_id, keys) do
    with :ok <- payment_method_id(payment_method_id),
         {:ok, method} <- request(:get, "/v1/payment_methods/#{payment_method_id}", [], keys) do
      Mapper.payment_method(method)
    end
  end

  @impl MishkaPay.Provider
  def detach_payment_method(payment_method_id, keys) do
    with :ok <- payment_method_id(payment_method_id),
         {:ok, method} <-
           request(:post, "/v1/payment_methods/#{payment_method_id}/detach", %{}, keys) do
      Mapper.payment_method(method)
    end
  end

  @impl MishkaPay.Provider
  def set_default_payment_method(customer_id, payment_method_id, keys) do
    with :ok <- stripe_id(customer_id, "cus_", :customer_id),
         :ok <- payment_method_id(payment_method_id),
         {:ok, customer} <-
           request(
             :post,
             "/v1/customers/#{customer_id}",
             %{"invoice_settings" => %{"default_payment_method" => payment_method_id}},
             keys
           ) do
      Mapper.customer(customer)
    end
  end

  # Stripe's payment method ids start with `pm_`, and `card_` for a card saved before them.
  defp payment_method_id("card_" <> _ = id), do: stripe_id(id, "card_", :payment_method_id)
  defp payment_method_id(id), do: stripe_id(id, "pm_", :payment_method_id)

  @impl MishkaPay.Provider
  def create_coupon(%Coupon{} = coupon, keys) do
    with :ok <- plain_id(coupon.id, :id),
         :ok <- metadata(coupon.metadata),
         :ok <- money_off(coupon.amount_off),
         {:ok, answer} <- request(:post, "/v1/coupons", Mapper.coupon_params(coupon), keys) do
      Mapper.coupon(answer)
    end
  end

  @impl MishkaPay.Provider
  def fetch_coupon(coupon_id, keys) do
    with :ok <- plain_id(coupon_id, :coupon_id),
         {:ok, answer} <- request(:get, "/v1/coupons/#{coupon_id}", [], keys) do
      Mapper.coupon(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_coupons(opts, keys), do: page("/v1/coupons", [], opts, keys, &Mapper.coupon/1)

  @impl MishkaPay.Provider
  def delete_coupon(coupon_id, keys) do
    with :ok <- plain_id(coupon_id, :coupon_id),
         {:ok, _deleted} <- request(:delete, "/v1/coupons/#{coupon_id}", [], keys),
         do: :ok
  end

  @impl MishkaPay.Provider
  def create_promotion_code(%PromotionCode{} = code, keys) do
    with :ok <- plain_id(code.coupon_id, :coupon_id),
         :ok <- metadata(code.metadata),
         :ok <- money_off(code.minimum_amount),
         {:ok, answer} <-
           request(:post, "/v1/promotion_codes", Mapper.promotion_code_params(code), keys) do
      Mapper.promotion_code(answer)
    end
  end

  @impl MishkaPay.Provider
  def fetch_promotion_code(promotion_code_id, keys) do
    with :ok <- stripe_id(promotion_code_id, "promo_", :promotion_code_id),
         {:ok, answer} <- request(:get, "/v1/promotion_codes/#{promotion_code_id}", [], keys) do
      Mapper.promotion_code(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_promotion_codes(opts, keys) do
    filters = [code: opts[:code], coupon: opts[:coupon_id], active: opts[:active]]
    page("/v1/promotion_codes", filters, opts, keys, &Mapper.promotion_code/1)
  end

  @impl MishkaPay.Provider
  def update_promotion_code(%PromotionCode{id: id} = code, keys) do
    with :ok <- stripe_id(id, "promo_", :id),
         :ok <- metadata(code.metadata),
         {:ok, answer} <-
           request(
             :post,
             "/v1/promotion_codes/#{id}",
             Mapper.promotion_code_update_params(code),
             keys
           ) do
      Mapper.promotion_code(answer)
    end
  end

  @impl MishkaPay.Provider
  def create_product(%Product{} = product, keys) do
    with :ok <- plain_id(product.id, :id),
         :ok <- metadata(product.metadata),
         {:ok, answer} <- request(:post, "/v1/products", Mapper.product_params(product), keys) do
      Mapper.product(answer)
    end
  end

  @impl MishkaPay.Provider
  def fetch_product(product_id, keys) do
    with :ok <- plain_id(product_id, :product_id),
         {:ok, answer} <- request(:get, "/v1/products/#{product_id}", [], keys) do
      Mapper.product(answer)
    end
  end

  @impl MishkaPay.Provider
  def update_product(%Product{id: id} = product, keys) do
    with :ok <- plain_id(id, :id),
         :ok <- metadata(product.metadata),
         {:ok, answer} <-
           request(:post, "/v1/products/#{id}", Mapper.product_params(%{product | id: nil}), keys) do
      Mapper.product(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_products(opts, keys),
    do: page("/v1/products", [active: opts[:active]], opts, keys, &Mapper.product/1)

  @impl MishkaPay.Provider
  def create_price(%Price{} = price, keys) do
    with :ok <- plain_id(price.product_id, :product_id),
         :ok <- maybe_id(price.meter_id, "mtr_", :meter_id),
         :ok <- currencies([price]),
         :ok <- metadata(price.metadata),
         {:ok, answer} <- request(:post, "/v1/prices", Mapper.price_params(price), keys) do
      Mapper.price(answer)
    end
  end

  @impl MishkaPay.Provider
  def fetch_price(price_id, keys) do
    with :ok <- stripe_id(price_id, "price_", :price_id),
         {:ok, answer} <-
           request(:get, "/v1/prices/#{price_id}", [{"expand[]", "product"}], keys) do
      Mapper.price(answer)
    end
  end

  @impl MishkaPay.Provider
  def update_price(%Price{id: id} = price, keys) do
    with :ok <- stripe_id(id, "price_", :id),
         :ok <- metadata(price.metadata),
         {:ok, answer} <-
           request(
             :post,
             "/v1/prices/#{id}",
             %{"active" => price.active, "metadata" => price.metadata},
             keys
           ) do
      Mapper.price(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_prices(opts, keys) do
    with :ok <- maybe_id(opts[:product_id], "", :product_id) do
      filters = [
        product: opts[:product_id],
        "lookup_keys[]": opts[:lookup_key],
        active: opts[:active],
        "expand[]": "data.product"
      ]

      page("/v1/prices", filters, opts, keys, &Mapper.price/1)
    end
  end

  @impl MishkaPay.Provider
  def fetch_dispute(dispute_id, keys) do
    with :ok <- dispute_id(dispute_id),
         {:ok, answer} <- request(:get, "/v1/disputes/#{dispute_id}", [], keys) do
      Mapper.dispute(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_disputes(opts, keys) do
    with :ok <- maybe_id(opts[:payment_id], "pi_", :payment_id) do
      page("/v1/disputes", [payment_intent: opts[:payment_id]], opts, keys, &Mapper.dispute/1)
    end
  end

  @impl MishkaPay.Provider
  def update_dispute(evidence, keys) do
    with :ok <- dispute_id(evidence.dispute_id),
         :ok <- metadata(evidence.metadata),
         :ok <- evidence_files(evidence.evidence),
         {:ok, answer} <-
           request(
             :post,
             "/v1/disputes/#{evidence.dispute_id}",
             %{
               "evidence" => evidence.evidence,
               "submit" => evidence.submit,
               "metadata" => evidence.metadata
             },
             keys
           ) do
      Mapper.dispute(answer)
    end
  end

  @impl MishkaPay.Provider
  def upload_file(%MishkaPay.FileUpload{} = upload, keys) do
    with :ok <- file_fits(upload),
         {:ok, answer} <-
           request(:post, "/v1/files", Mapper.file_params(upload), keys, upload: true) do
      Mapper.file(answer)
    end
  end

  @impl MishkaPay.Provider
  def fetch_file(file_id, keys) do
    with :ok <- stripe_id(file_id, "file_", :file_id),
         {:ok, answer} <- request(:get, "/v1/files/#{file_id}", [], keys) do
      Mapper.file(answer)
    end
  end

  @impl MishkaPay.Provider
  def file_link(file_id, opts, keys) do
    with :ok <- stripe_id(file_id, "file_", :file_id),
         :ok <- link_expiry(opts[:expires_at]),
         {:ok, answer} <-
           request(:post, "/v1/file_links", Mapper.file_link_params(file_id, opts), keys) do
      Mapper.file_link(answer)
    end
  end

  # A file of a type Stripe takes for its purpose, within its size, whose bytes are that type.
  defp file_fits(%{purpose: purpose, content_type: type, content: bytes}) do
    {most, types} = Map.fetch!(@file_rules, purpose)

    case Map.fetch(types, type) do
      :error ->
        invalid(:content_type, Messages.text(:stripe_file_type, types: "PDF, JPEG or PNG"))

      {:ok, _magic} when byte_size(bytes) > most ->
        invalid(:content, Messages.text(:stripe_file_size, megabytes: div(most, 1_000_000)))

      {:ok, magic} ->
        case String.starts_with?(bytes, magic) do
          true -> :ok
          false -> invalid(:content, Messages.text(:file_content, content_type: type))
        end
    end
  end

  defp link_expiry(nil), do: :ok

  defp link_expiry(%DateTime{} = at) do
    case DateTime.after?(at, DateTime.utc_now()) do
      true -> :ok
      false -> invalid(:expires_at, Messages.text(:expires_past))
    end
  end

  defp link_expiry(_not_a_time), do: invalid(:expires_at, Messages.text(:expires_past))

  # The evidence fields that hold a file take only a Stripe file id.
  defp evidence_files(nil), do: :ok

  defp evidence_files(evidence) do
    evidence
    |> Map.take(Mapper.evidence_files())
    |> Enum.find_value(:ok, fn {_name, id} ->
      with :ok <- stripe_id(id, "file_", :evidence), do: nil
    end)
  end

  @impl MishkaPay.Provider
  def fetch_fraud_warning(warning_id, keys) do
    with :ok <- stripe_id(warning_id, "issfr_", :warning_id),
         {:ok, answer} <- request(:get, "/v1/radar/early_fraud_warnings/#{warning_id}", [], keys) do
      Mapper.fraud_warning(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_fraud_warnings(opts, keys) do
    with :ok <- maybe_id(opts[:payment_id], "pi_", :payment_id),
         :ok <- maybe_id(opts[:charge_id], "", :charge_id) do
      filters = [payment_intent: opts[:payment_id], charge: opts[:charge_id]]
      page("/v1/radar/early_fraud_warnings", filters, opts, keys, &Mapper.fraud_warning/1)
    end
  end

  @impl MishkaPay.Provider
  def fetch_fraud_review(review_id, keys) do
    with :ok <- stripe_id(review_id, "prv_", :review_id),
         {:ok, answer} <- request(:get, "/v1/reviews/#{review_id}", [], keys) do
      Mapper.fraud_review(answer)
    end
  end

  # Stripe lists only the reviews still open.
  @impl MishkaPay.Provider
  def list_fraud_reviews(opts, keys),
    do: page("/v1/reviews", [], opts, keys, &Mapper.fraud_review/1)

  @impl MishkaPay.Provider
  def approve_fraud_review(review_id, keys) do
    with :ok <- stripe_id(review_id, "prv_", :review_id),
         {:ok, answer} <- request(:post, "/v1/reviews/#{review_id}/approve", %{}, keys) do
      Mapper.fraud_review(answer)
    end
  end

  @impl MishkaPay.Provider
  def accept_dispute(dispute_id, keys) do
    with :ok <- dispute_id(dispute_id),
         {:ok, answer} <- request(:post, "/v1/disputes/#{dispute_id}/close", %{}, keys) do
      Mapper.dispute(answer)
    end
  end

  @impl MishkaPay.Provider
  def create_payment_link(%PaymentLink{} = link, keys) do
    with :ok <- metadata(link.metadata),
         :ok <- link_prices(link.items),
         {:ok, answer} <-
           request(:post, "/v1/payment_links", Mapper.payment_link_params(link, keys), keys) do
      Mapper.payment_link(answer)
    end
  end

  @impl MishkaPay.Provider
  def fetch_payment_link(payment_link_id, keys) do
    with :ok <- stripe_id(payment_link_id, "plink_", :payment_link_id),
         {:ok, answer} <-
           request(
             :get,
             "/v1/payment_links/#{payment_link_id}",
             [{"expand[]", "line_items"}],
             keys
           ) do
      Mapper.payment_link(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_payment_links(opts, keys),
    do:
      page(
        "/v1/payment_links",
        [active: opts[:active], "expand[]": "data.line_items"],
        opts,
        keys,
        &Mapper.payment_link/1
      )

  @impl MishkaPay.Provider
  def update_payment_link(%PaymentLink{id: id} = link, keys) do
    with :ok <- stripe_id(id, "plink_", :id),
         :ok <- metadata(link.metadata),
         {:ok, answer} <-
           request(
             :post,
             "/v1/payment_links/#{id}",
             Mapper.payment_link_update_params(link),
             keys
           ) do
      Mapper.payment_link(answer)
    end
  end

  @impl MishkaPay.Provider
  def create_meter(%MishkaPay.Meter{} = meter, keys) do
    with {:ok, answer} <- request(:post, "/v1/billing/meters", Mapper.meter_params(meter), keys) do
      Mapper.meter(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_meters(opts, keys),
    do: page("/v1/billing/meters", [status: opts[:status]], opts, keys, &Mapper.meter/1)

  @impl MishkaPay.Provider
  def deactivate_meter(meter_id, keys) do
    with :ok <- stripe_id(meter_id, "mtr_", :meter_id),
         {:ok, answer} <-
           request(:post, "/v1/billing/meters/#{meter_id}/deactivate", %{}, keys) do
      Mapper.meter(answer)
    end
  end

  @impl MishkaPay.Provider
  def reactivate_meter(meter_id, keys) do
    with :ok <- stripe_id(meter_id, "mtr_", :meter_id),
         {:ok, answer} <-
           request(:post, "/v1/billing/meters/#{meter_id}/reactivate", %{}, keys) do
      Mapper.meter(answer)
    end
  end

  @impl MishkaPay.Provider
  def fetch_meter(meter_id, keys) do
    with :ok <- stripe_id(meter_id, "mtr_", :meter_id),
         {:ok, answer} <- request(:get, "/v1/billing/meters/#{meter_id}", [], keys) do
      Mapper.meter(answer)
    end
  end

  # Stripe changes only a meter's display name; its event name and aggregation stay.
  @impl MishkaPay.Provider
  def update_meter(%MishkaPay.Meter{id: id, name: name}, keys) do
    with :ok <- stripe_id(id, "mtr_", :id),
         {:ok, answer} <-
           request(:post, "/v1/billing/meters/#{id}", %{"display_name" => name}, keys) do
      Mapper.meter(answer)
    end
  end

  # One cancel per report: the report's identifier makes the idempotency key.
  @impl MishkaPay.Provider
  def cancel_usage(%MishkaPay.UsageCancellation{} = cancel, keys) do
    key =
      ProviderKit.idempotency_key("usage-cancel", cancel.tenant, {
        cancel.event_name,
        cancel.usage_id
      })

    with {:ok, answer} <-
           request(
             :post,
             "/v1/billing/meter_event_adjustments",
             Mapper.usage_cancellation_params(cancel),
             keys,
             key: key
           ) do
      Mapper.usage_cancellation(answer, cancel)
    end
  end

  # The reference makes the report's `identifier`, which Stripe never counts twice, and the
  # request's idempotency key, so a report sent again after a lost answer gets the same answer.
  @impl MishkaPay.Provider
  def report_usage(%MishkaPay.Usage{} = usage, keys) do
    identifier = ProviderKit.idempotency_key("usage", usage.tenant, usage.reference)

    with :ok <- stripe_id(usage.customer_id, "cus_", :customer_id),
         :ok <- usage_time(usage.at),
         {:ok, answer} <-
           request(
             :post,
             "/v1/billing/meter_events",
             Mapper.usage_params(usage, identifier),
             keys,
             key: identifier
           ) do
      {:ok, Mapper.usage(answer, usage)}
    end
  end

  # Stripe takes usage from the last 35 days, and up to 5 minutes ahead for clocks that drift.
  defp usage_time(nil), do: :ok

  defp usage_time(%DateTime{} = at) do
    seconds = DateTime.diff(at, DateTime.utc_now())

    case seconds >= -35 * 24 * 60 * 60 and seconds <= 5 * 60 do
      true -> :ok
      false -> invalid(:at, Messages.text(:stripe_usage_time))
    end
  end

  @impl MishkaPay.Provider
  def usage_summary(meter_id, opts, keys) do
    params = Mapper.usage_summary_params(opts[:customer_id], opts[:from], opts[:to])

    with :ok <- stripe_id(meter_id, "mtr_", :meter_id),
         :ok <- stripe_id(opts[:customer_id], "cus_", :customer_id),
         {:ok, answer} <-
           request(:get, "/v1/billing/meters/#{meter_id}/event_summaries", params, keys) do
      Mapper.usage_summary(answer, meter_id, opts[:customer_id], params)
    end
  end

  @impl MishkaPay.Provider
  def create_feature(%MishkaPay.Feature{} = feature, keys) do
    with :ok <- metadata(feature.metadata),
         {:ok, answer} <-
           request(:post, "/v1/entitlements/features", Mapper.feature_params(feature), keys) do
      Mapper.feature(answer)
    end
  end

  @impl MishkaPay.Provider
  def attach_feature(product_id, feature_id, keys) do
    with :ok <- plain_id(product_id, :product_id),
         :ok <- stripe_id(feature_id, "feat_", :feature_id),
         {:ok, answer} <-
           request(
             :post,
             "/v1/products/#{product_id}/features",
             %{"entitlement_feature" => feature_id},
             keys
           ) do
      Mapper.feature(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_entitlements(opts, keys) do
    with :ok <- stripe_id(opts[:customer_id], "cus_", :customer_id) do
      page(
        "/v1/entitlements/active_entitlements",
        [customer: opts[:customer_id]],
        opts,
        keys,
        &Mapper.entitlement/1
      )
    end
  end

  @impl MishkaPay.Provider
  def fetch_balance(keys) do
    with {:ok, answer} <- request(:get, "/v1/balance", [], keys), do: Mapper.balance(answer)
  end

  @impl MishkaPay.Provider
  def list_balance_transactions(opts, keys) do
    with :ok <- maybe_id(opts[:payout_id], "po_", :payout_id),
         :ok <- maybe_id(opts[:type], "", :type) do
      page(
        "/v1/balance_transactions",
        [payout: opts[:payout_id], type: opts[:type]],
        opts,
        keys,
        &Mapper.balance_transaction/1
      )
    end
  end

  @impl MishkaPay.Provider
  def adjust_customer_balance(%MishkaPay.CustomerBalanceTransaction{} = txn, keys) do
    with :ok <- stripe_id(txn.customer_id, "cus_", :customer_id),
         :ok <- currencies([txn]),
         {:ok, answer} <-
           request(
             :post,
             "/v1/customers/#{txn.customer_id}/balance_transactions",
             Mapper.customer_balance_params(txn),
             keys,
             key: ProviderKit.idempotency_key("customer-balance", txn.tenant, txn.reference)
           ) do
      Mapper.customer_balance_transaction(answer)
    end
  end

  @impl MishkaPay.Provider
  def list_customer_balance(opts, keys) do
    customer_id = opts[:customer_id]

    with :ok <- stripe_id(customer_id, "cus_", :customer_id) do
      page(
        "/v1/customers/#{customer_id}/balance_transactions",
        [],
        opts,
        keys,
        &Mapper.customer_balance_transaction/1
      )
    end
  end

  defp link_prices(items) do
    case Enum.find(items, &(not stripe_price?(&1.id))) do
      nil -> :ok
      _bad -> stripe_id("not a price", "price_", :items)
    end
  end

  defp stripe_price?(id), do: stripe_id(id, "price_", :items) == :ok
  defp shipping_rate?(id), do: stripe_id(id, "shr_", :shipping_rates) == :ok

  # One page of a Stripe list: the list options as Stripe's `limit` and `starting_after`, the
  # filters set, each item mapped; the next cursor is the last item's id when Stripe has more.
  defp page(path, filters, opts, keys, map) do
    params =
      [limit: opts[:limit], starting_after: opts[:after]]
      |> Kernel.++(filters)
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Enum.map(fn {name, value} -> {Atom.to_string(name), to_string(value)} end)

    with {:ok, %{"data" => data} = answer} <- request(:get, path, params, keys),
         {:ok, items} <- data |> Enum.map(map) |> all_ok() do
      more = answer["has_more"] == true and data != []

      {:ok,
       struct(Page, items: items, has_more: more, next: (more && List.last(data)["id"]) || nil)}
    end
  end

  # Stripe's dispute ids start with `du_` now and `dp_` on older disputes.
  defp dispute_id("du_" <> _ = id), do: stripe_id(id, "du_", :dispute_id)
  defp dispute_id(id), do: stripe_id(id, "dp_", :dispute_id)

  # A filter id is checked only when it is given: by its prefix, or as a plain id with no prefix.
  defp maybe_id(nil, _prefix, _field), do: :ok
  defp maybe_id(id, "", field), do: plain_id(id, field)
  defp maybe_id(id, prefix, field), do: stripe_id(id, prefix, field)

  # The same reference on the same method and path is the same call at Stripe; a read takes no key.
  @impl MishkaPay.Provider
  def raw_request(%MishkaPay.RawRequest{} = call, keys) do
    request(call.method, call.path, call.params || [], keys,
      key: MishkaPay.RawRequest.idempotency_key(call),
      request_options: call.options
    )
  end

  # The lightest read every key may make: one customer, or none.
  @impl MishkaPay.Provider
  def check_keys(keys) do
    with {:ok, _page} <- request(:get, "/v1/customers", [{"limit", "1"}], keys), do: :ok
  end

  # Stripe keeps events for 30 days and filters them by type, up to 20 types a call.
  @impl MishkaPay.Provider
  def list_events(opts, keys) do
    types = List.wrap(opts[:types])

    case Enum.drop(types, 20) != [] do
      true ->
        invalid(:types, Messages.text(:stripe_event_types))

      false ->
        filters =
          [{:"created[gte]", opts[:since] && DateTime.to_unix(opts[:since])}] ++
            Enum.map(types, &{:"types[]", &1})

        page("/v1/events", filters, opts, keys, &Mapper.event/1)
    end
  end

  @impl MishkaPay.Provider
  def verify_webhook(payload, headers, keys) when is_binary(payload) do
    with {:ok, secrets} <- webhook_secrets(keys),
         {:ok, header} <- signature_header(headers),
         {:ok, timestamp, signatures} <- parse_signature(header),
         :ok <- fresh(timestamp),
         :ok <- signed(payload, timestamp, signatures, secrets),
         {:ok, %{} = event} <- decode(payload),
         :ok <- same_mode(event, keys),
         :ok <- same_account(event, keys) do
      Mapper.event(event)
    end
  end

  @doc """
  Stripe's signature of `payload` at `timestamp` (Unix seconds) with webhook `secret`: the `v1`
  value of a `Stripe-Signature` header. `verify_webhook/3` compares with it, and a test signs a
  message with it.
  """
  @spec signature(binary(), integer(), String.t()) :: String.t()
  def signature(payload, timestamp, secret),
    do:
      :hmac
      |> :crypto.mac(:sha256, secret, "#{timestamp}.#{payload}")
      |> Base.encode16(case: :lower)

  defp webhook_secrets(keys) do
    case MishkaPay.Credentials.webhook_secrets(keys) do
      [] ->
        {:error,
         Errors.MissingCredentials.exception(
           provider: "stripe",
           tenant: keys.tenant,
           reason: :no_webhook_secret
         )}

      secrets ->
        {:ok, secrets}
    end
  end

  defp signature_header(headers) do
    case for({name, value} <- headers, String.downcase(name) == "stripe-signature", do: value) do
      [header | _] -> {:ok, header}
      [] -> bad(:missing)
    end
  end

  # `t=1700000000,v1=abc...,v1=def...,v0=...`: the time and every v1 signature (a rolled secret
  # signs with old and new for a while).
  defp parse_signature(header) do
    parts =
      for part <- String.split(header, ","),
          [k, v] <- [String.split(String.trim(part), "=", parts: 2)],
          do: {k, v}

    with {_t, time} <- List.keyfind(parts, "t", 0),
         {timestamp, ""} <- Integer.parse(time),
         [_ | _] = signatures <- for({"v1", sig} <- parts, do: sig) do
      {:ok, timestamp, signatures}
    else
      _unreadable -> bad(:malformed)
    end
  end

  defp fresh(timestamp) do
    tolerance =
      :mishka_pay |> Application.get_env(__MODULE__, []) |> Keyword.get(:webhook_tolerance, 300)

    case abs(System.system_time(:second) - timestamp) <= tolerance do
      true -> :ok
      false -> bad(:too_old)
    end
  end

  # Each of the tenant's secrets (a rolled one and the new one) against every v1 signature, each
  # comparison in constant time.
  defp signed(payload, timestamp, signatures, secrets) do
    verified? =
      Enum.any?(secrets, fn secret ->
        expected = signature(payload, timestamp, secret)
        Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected))
      end)

    case verified? do
      true -> :ok
      false -> bad(:mismatch)
    end
  end

  defp decode(payload) do
    case JSON.decode(payload) do
      {:ok, %{} = event} -> {:ok, event}
      _not_an_object -> bad(:malformed)
    end
  end

  # A live event checked with test keys, or the other way round, is not this tenant's.
  defp same_mode(%{"livemode" => livemode}, keys) when is_boolean(livemode) do
    case livemode == (keys.mode == :live) do
      true -> :ok
      false -> bad(:mode)
    end
  end

  defp same_mode(_event, _keys), do: bad(:malformed)

  # A tenant that acts for a connected account takes only that account's events: one about the
  # platform's own account (no `account`) or another connected account is not this tenant's. The
  # platform's own keys (no `:account_id`) take its connected accounts' events too, each naming
  # its `:account`, for the host to tell which of its sites it is about.
  defp same_account(event, keys) do
    case {Map.get(keys, :account_id), event["account"]} do
      {nil, _any} -> :ok
      {account, account} -> :ok
      _another -> bad(:account)
    end
  end

  defp bad(reason),
    do: {:error, Errors.BadSignature.exception(provider: "stripe", reason: reason)}

  # Public for the Stripe-only helpers beside this adapter (`MishkaPay.Providers.Stripe.TestClock`).
  # `upload: true` sends `params` as multipart parts to Stripe's files host; `request_options:` (a
  # `MishkaPay.RequestOptions`) another API version and the objects to expand. The tenant's
  # connected account (`:account_id` in its keys) goes in `Stripe-Account` on every request, so
  # each call is made as that account; nothing else sets the header.
  @doc false
  def request(method, path, params, keys, opts \\ []) do
    options = opts[:request_options] || %RequestOptions{}
    account_id = Map.get(keys, :account_id)

    with :ok <- maybe_id(account_id, "acct_", :account_id) do
      %{
        provider: "stripe",
        method: method,
        base_url: base_url(opts[:upload] == true),
        path: path,
        auth: {:bearer, keys.secret_key},
        headers: headers(options, account_id),
        idempotency_header: "idempotency-key",
        idempotency_key: opts[:key],
        retry_header: "stripe-should-retry",
        limit_header: "stripe-rate-limited-reason"
      }
      |> put_body(method, expanded(params, options.expand), opts[:upload] == true)
      |> Client.request()
      |> answer()
    end
  end

  defp headers(options, nil), do: %{"stripe-version" => options.api_version || @version}

  defp headers(options, account_id),
    do: options |> headers(nil) |> Map.put("stripe-account", account_id)

  # Stripe takes `expand[]` in a read's query and in a write's form alike.
  defp expanded(params, nil), do: params
  defp expanded(params, paths), do: form(params) ++ Enum.map(paths, &{"expand[]", &1})

  defp put_body(spec, _method, parts, true), do: Map.put(spec, :multipart, parts)
  defp put_body(spec, :get, params, false), do: Map.put(spec, :params, form(params))
  defp put_body(spec, _write, params, false), do: Map.put(spec, :form, form(params))

  defp answer({:ok, %Req.Response{status: status, body: %{} = body}}) when status in 200..299,
    do: {:ok, body}

  defp answer({:ok, %Req.Response{status: 402, body: %{"error" => error}} = response}) do
    {:error,
     Errors.Declined.exception(
       provider: "stripe",
       reason: error["decline_code"] || error["code"],
       answer: error,
       request_id: request_id(response),
       doc_url: error["doc_url"]
     )}
  end

  defp answer({:ok, %Req.Response{status: status, body: body} = response}) do
    error = error_of(body)

    {:error,
     Errors.Rejected.exception(
       provider: "stripe",
       status: status,
       code: code_of(error),
       param: field_of(error["param"] || param_in(error["message"])),
       message: error["message"],
       request_id: request_id(response),
       doc_url: error["doc_url"],
       rate_limit_reason:
         response |> Req.Response.get_header("stripe-rate-limited-reason") |> List.first()
     )}
  end

  defp answer({:error, _unreachable} = error), do: error

  defp error_of(%{"error" => %{} = error}), do: error
  defp error_of(_other), do: %{}

  # Stripe names every request in its `Request-Id` header (`req_...`): its support and the
  # Dashboard's request log find a failed one by it.
  defp request_id(response), do: response |> Req.Response.get_header("request-id") |> List.first()

  # Stripe's names of the fields Mishka Pay calls otherwise; any other is kept as Stripe says it.
  @fields [
    {"payment_intent_data.statement_descriptor_suffix", "statement_suffix"},
    {"subscription_data", "trial_days"},
    {"restrictions", "max_purchases"},
    {"proration_behavior", "proration"},
    {"invoice_creation", "invoice"},
    {"managed_payments", "merchant_of_record"},
    {"after_completion", "success_url"},
    {"shipping_options", "shipping_rates"},
    {"shipping_address_collection", "shipping_countries"}
  ]

  defp field_of(nil), do: nil

  defp field_of(param) do
    cond do
      param =~ "adjustable_quantity][minimum]" ->
        "quantity_min"

      param =~ "adjustable_quantity][maximum]" ->
        "quantity_max"

      true ->
        Enum.find_value(@fields, param, fn {stripe, ours} ->
          String.starts_with?(param, stripe) && ours
        end)
    end
  end

  # Some refusals name their field only in their words: "`invoice_creation` can only be used...",
  # or a product without the tax code Managed Payments needs.
  defp param_in(message) when is_binary(message) do
    cond do
      String.contains?(message, "product tax code is missing") ->
        "tax_code"

      String.contains?(message, "separate authorization and capture") ->
        "capture"

      match = Regex.run(~r/\A`(\w+)` can only be used/, message) ->
        List.last(match)

      match = Regex.run(~r/\A(\S+) cannot be used with Managed Payments/, message) ->
        List.last(match)

      true ->
        nil
    end
  end

  defp param_in(_no_message), do: nil

  # Stripe gives a reused idempotency key a type and no code, and a code or id already taken only
  # its words; so is an invoice turned off where Managed Payments must make one, a product without
  # the tax code it needs, a choice that belongs only to one-time or only to recurring prices, and
  # a hold on the card where an invoice is made after payment.
  defp code_of(%{"type" => "idempotency_error"}), do: "idempotency_error"

  # Stripe Tax turned off on the account, and an address it cannot count the tax for.
  defp code_of(%{"code" => "stripe_tax_inactive"}), do: "tax_not_set_up"

  defp code_of(%{"code" => code})
       when code in ["customer_tax_location_invalid", "invalid_tax_location"],
       do: "tax_location_invalid"

  defp code_of(%{"code" => code}) when is_binary(code), do: code

  # Stripe's words for a refusal it gives no code, first match wins: shipping where Managed
  # Payments sells is named before any other choice it refuses there.
  @worded [
    {"already exists", "already_exists"},
    {"when Managed Payments is enabled", "managed_payments_invoice"},
    {"Shipping parameters cannot be used with Managed", "managed_payments_shipping"},
    {"cannot be used with Managed Payments", "merchant_of_record_off"},
    {"product tax code is missing", "tax_code_missing"},
    {"does not contain any recurring prices", "one_time_only"},
    {"must pass a recurring price", "recurring_only"},
    {"separate authorization and capture", "capture_invoice"},
    {"Stripe Tax has not been activated", "tax_not_set_up"},
    {"feature in the portal configuration is disabled", "portal_feature_off"},
    {"customer does not match the subscription's customer", "subscription_of_another"}
  ]

  defp code_of(%{"message" => message}) when is_binary(message),
    do: Enum.find_value(@worded, fn {words, code} -> String.contains?(message, words) && code end)

  defp code_of(_no_code), do: nil

  # Stripe takes a checkout's expiry between 30 minutes and 24 hours from now.
  defp expiry(nil), do: :ok

  defp expiry(%DateTime{} = at) do
    seconds = DateTime.diff(at, DateTime.utc_now())

    case seconds >= 30 * 60 and seconds <= 24 * 60 * 60 do
      true -> :ok
      false -> ProviderKit.invalid(:expires_at, Messages.text(:expires_range, min: 30, max: 24))
    end
  end

  # A coupon's or a code's own id goes into a path: letters, digits, `_` and `-` only.
  defp plain_id(nil, _field), do: :ok

  defp plain_id(id, field) do
    case Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id) do
      true -> :ok
      false -> ProviderKit.invalid(field, Messages.text(:plain_id, field: field))
    end
  end

  # Money off or a minimum in a currency Stripe counts its own way is refused, like a price.
  defp money_off(nil), do: :ok
  defp money_off(money), do: currencies([%{amount: money}])

  # A Stripe id is its object's prefix, then letters, digits and underscores; anything else never
  # reaches a path, and an id of another kind (a checkout id read as a payment) is refused here.
  defp stripe_id(id, prefix, field) do
    case is_binary(id) and String.starts_with?(id, prefix) and
           Regex.match?(~r/\A[A-Za-z0-9_]+\z/, id) do
      true ->
        :ok

      false ->
        Errors.from_builder(
          {:error,
           [
             %{
               field: field,
               action: :stripe_id,
               message: Messages.text(:stripe_id, field: field, prefix: prefix)
             }
           ]}
        )
    end
  end

  # Stripe keeps up to 50 metadata keys (two are the reference and the owner), of 40 characters, with values of
  # 500.
  defp metadata(nil), do: :ok

  defp metadata(metadata) do
    case map_size(metadata) < 49 and
           Enum.all?(metadata, fn {key, value} ->
             String.length(key) <= 40 and String.length(value) <= 500
           end) do
      true ->
        :ok

      false ->
        invalid(
          :metadata,
          Messages.text(:stripe_metadata)
        )
    end
  end

  defp invalid(field, message), do: ProviderKit.invalid(field, message)

  # Stripe takes no statement suffix while it sells as merchant of record (Managed Payments): a
  # checkout or a site that turns it on is refused before the request.
  defp suffix_fits(%Checkout{statement_suffix: nil}, _keys), do: :ok

  defp suffix_fits(%Checkout{merchant_of_record: on?} = checkout, keys) do
    case on? == true or (is_nil(on?) and Map.get(keys, :merchant_of_record) == true) do
      true ->
        invalid(
          :statement_suffix,
          Messages.text(:merchant_of_record_off, param: "statement_suffix")
        )

      false ->
        suffix_mode(checkout)
    end
  end

  defp suffix_mode(%Checkout{mode: :subscription}),
    do: invalid(:statement_suffix, Messages.text(:one_time_only, param: "statement_suffix"))

  defp suffix_mode(_one_time), do: :ok

  # Stripe counts ISK, UGX and MGA in whole units only, and BHD, JOD, KWD, OMR and TND with a last
  # decimal of 0; an amount Stripe would read otherwise is refused before any request.
  defp currencies(items) do
    case Enum.find(items, &(not whole_ok?(&1))) do
      nil -> three_decimal(items)
      %{amount: money} -> invalid(:amount, Messages.text(:stripe_whole, currency: money.currency))
    end
  end

  defp whole_ok?(%{amount: %Money{currency: currency} = money}) do
    case Mapper.digits(currency) do
      nil -> true
      _stripe_places -> MishkaPay.Money.fits?(money, 0)
    end
  end

  defp whole_ok?(_item), do: true

  # Stripe takes BHD, JOD, KWD, OMR and TND only in amounts whose last decimal is 0.
  defp three_decimal(items) do
    case Enum.all?(items, &three_decimal_ok?/1) do
      true ->
        :ok

      false ->
        invalid(:amount, Messages.text(:stripe_three_decimal))
    end
  end

  defp three_decimal_ok?(%{amount: %Money{currency: currency} = money})
       when currency in @three_decimal,
       do: rem(MishkaPay.Money.to_minor(money), 10) == 0

  defp three_decimal_ok?(_item), do: true

  # The API's address, or the files host's for an upload: its own setting, else the API's.
  defp base_url(upload?) do
    config = Application.get_env(:mishka_pay, __MODULE__, [])

    case upload? do
      true -> config[:files_url] || Keyword.get(config, :base_url, @files_url)
      false -> Keyword.get(config, :base_url, @base_url)
    end
  end

  @doc """
  Stripe's form encoding of nested params: `%{"line_items" => [%{"quantity" => 1}]}` becomes
  `[{"line_items[0][quantity]", "1"}]`. `nil` values are left out.
  """
  @spec form(map() | list()) :: [{String.t(), String.t()}]
  def form(params) when is_list(params), do: params

  def form(params) when is_map(params),
    do: Enum.flat_map(params, fn {key, value} -> pairs(to_string(key), value) end)

  defp pairs(_key, nil), do: []
  defp pairs(key, %{} = map), do: Enum.flat_map(map, fn {k, v} -> pairs("#{key}[#{k}]", v) end)

  defp pairs(key, list) when is_list(list),
    do: list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> pairs("#{key}[#{i}]", v) end)

  defp pairs(key, value), do: [{key, to_string(value)}]
end

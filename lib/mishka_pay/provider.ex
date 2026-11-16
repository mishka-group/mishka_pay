# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Provider do
  @moduledoc """
  Every payment provider, Stripe included, implements these callbacks. A provider is one module:

      defmodule MyApp.Pay.Acme do
        use MishkaPay.Provider,
          id: "acme",
          label: "Acme Pay",
          capabilities: [:checkout, :refund, :webhook]
      end

  Supervise the module in the application that ships it, like any other mishka_installer plugin.
  `use` makes it a plugin on the `mishka_pay:providers` event (`MishkaPay.Events.providers/0`): it
  adds itself to the `providers` list the event carries. Supervising it installs the provider, and
  stopping its plugin in the installer takes it out. A project adds its own payment method the same
  way, without changing Mishka Pay.

  ## Options of `use`

    * `:id` (required): a short lowercase name, such as `"stripe"`. Every call names the provider by it.
    * `:label` (required): the name a person reads.
    * `:capabilities`: what the provider can do, from `t:capability/0`. A call to something not
      listed answers a `MishkaPay.Errors.Unsupported` error without reaching the provider.
    * `:priority`: the plugin's priority on the event, 50 by default. When two installed providers
      share an id, the one that comes first wins.

  ## Which providers are installed

  `all/0`, `offered/0` and `fetch/1` ask the event every time, so mishka_installer's own registry is
  the only list and nothing is cached. A module counts only when it implements every required
  callback. When a plugin of the event is registered but not loaded, the event cannot run and no
  provider can be told installed: `fetch/1` then answers a `MishkaPay.Errors.UnknownProvider` error
  with the reason `:cannot_run`.

  The same pattern as `MishkaCmsCore.ProviderRegistry` and `MishkaCmsCore.Captcha.Provider`.

  ## Operations

  Each capability brings the callbacks it needs, and a provider that declares a capability without
  them does not compile:

    * `:checkout`: `checkout/2`, `fetch_checkout/2` and `fetch_payment/2`;
    * `:expire`: `expire_checkout/2`;
    * `:payment_list`: `list_payments/2`;
    * `:refund`: `refund/2`;
    * `:refund_read`: `fetch_refund/2`, `list_refunds/2`;
    * `:subscription`: `fetch_subscription/2`, `cancel_subscription/3`, `resume_subscription/2`,
      `list_invoices/2`, `fetch_invoice/2` and `upcoming_invoice/2` (a subscription starts with a checkout in
      `mode: :subscription`);
    * `:subscription_change`: `change_subscription/2`, `preview_subscription_change/2`,
      `pause_collection/3`, `resume_collection/2`;
    * `:invoice`: `create_invoice/2`, `finalize_invoice/2`, `send_invoice/2`, `pay_invoice/3`,
      `void_invoice/2`, `mark_invoice_uncollectible/2`, `delete_invoice/2`;
    * `:customer`: `create_customer/2`, `fetch_customer/2`, `update_customer/2`, `list_customers/2`,
      `search_customers/2`;
    * `:portal`: `portal_session/2`;
    * `:discount`: coupons and promotion codes (`create_coupon/2` and the rest);
    * `:catalog`: products and prices (`create_product/2` and the rest);
    * `:payment_link`: `create_payment_link/2`, `fetch_payment_link/2`, `list_payment_links/2`,
      `update_payment_link/2`;
    * `:dispute`: `fetch_dispute/2`, `list_disputes/2`, `update_dispute/2`, `accept_dispute/2`;
    * `:usage`: `create_meter/2`, `list_meters/2`, `deactivate_meter/2`, `report_usage/2`,
      `usage_summary/3`;
    * `:entitlement`: `create_feature/2`, `attach_feature/3`, `list_entitlements/2`;
    * `:balance`: `fetch_balance/1`, `list_balance_transactions/2`;
    * `:customer_balance`: `adjust_customer_balance/2`, `list_customer_balance/2`;
    * `:webhook`: `verify_webhook/3`;
    * `:event_list`: `list_events/2`.

  Every `list_*` callback takes the list options (`:limit`, 1 to 100; `:after`, the cursor of a
  page before; and its own filters) and answers one `MishkaPay.Page`.

  Every operation takes a guarded_struct and the tenant's `MishkaPay.Credentials`, and answers a
  guarded_struct or a `MishkaPay.Errors` error. A project calls them through `MishkaPay`, which
  checks the capability, asks for the keys and emits telemetry first.
  """

  require Logger

  alias MishkaInstaller.Event.Hook
  alias MishkaPay.{Errors, Events}

  @capabilities [
    :checkout,
    :expire,
    :payment_list,
    :refund,
    :refund_read,
    :subscription,
    :subscription_change,
    :invoice,
    :customer,
    :portal,
    :discount,
    :catalog,
    :payment_link,
    :dispute,
    :usage,
    :entitlement,
    :balance,
    :customer_balance,
    :webhook,
    :event_list,
    :return_verify
  ]

  @typedoc """
  What a provider can do:

    * `:checkout`: sends the buyer to pay, or embeds a payment form.
    * `:expire`: ends an open checkout before the buyer pays, so its stock is free again.
    * `:payment_list`: lists past payments page by page.
    * `:refund`: gives money back on a payment.
    * `:refund_read`: reads a refund again, and lists refunds page by page.
    * `:subscription`: charges again on a schedule.
    * `:subscription_change`: changes a running subscription's plan or quantity with proration,
      previews what that bills, and pauses or resumes its collection.
    * `:invoice`: makes one-off bills for a customer, and opens, sends, settles or ends them.
    * `:customer`: keeps buyers (create, read, update, list).
    * `:portal`: has a hosted page where a customer manages their own billing.
    * `:discount`: keeps coupons and the promotion codes buyers type.
    * `:catalog`: keeps products and their prices, so a checkout sells a price by its id.
    * `:payment_link`: makes pages that sell catalog prices to anyone who opens them.
    * `:dispute`: reads chargebacks and answers them with evidence, or accepts them.
    * `:usage`: counts what customers use on meters, for prices billed by usage.
    * `:entitlement`: attaches features to products and tells which ones a customer may use.
    * `:balance`: reads the seller's balance and the movements that made it.
    * `:customer_balance`: keeps a customer's store credit, taken off their next bills.
    * `:webhook`: sends signed messages when something changes.
    * `:event_list`: lists the messages it sent, to deliver again those a site missed.
    * `:return_verify`: has no webhook; the buyer comes back to a return URL and the payment is
      checked with a call to the provider.
  """
  @type capability ::
          :checkout
          | :expire
          | :refund
          | :refund_read
          | :subscription
          | :subscription_change
          | :invoice
          | :customer
          | :portal
          | :discount
          | :catalog
          | :payment_link
          | :dispute
          | :usage
          | :entitlement
          | :balance
          | :customer_balance
          | :payment_list
          | :webhook
          | :event_list
          | :return_verify

  @doc "The provider's id, such as `\"stripe\"`. Set by `use`."
  @callback id() :: String.t()

  @doc "The name a person reads. Set by `use`."
  @callback label() :: String.t()

  @doc "What the provider can do. Set by `use`."
  @callback capabilities() :: [capability()]

  @doc "Optional. `false` keeps an installed provider out of `offered/0`, for example while it has no keys anywhere."
  @callback offered?() :: boolean()

  @doc """
  With `:checkout`. Opens a checkout at the provider with the tenant's keys and answers it with
  the provider's `:id`, `:url` and `:status` filled in.
  """
  @callback checkout(MishkaPay.Checkout.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Checkout.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:checkout`. Reads a checkout again by its id, as the buyer comes back to the success page:
  what the provider fills in (`:id`, `:url`, `:status`, `:payment_id`), with `:provider` and the
  caller's `:reference`. Its items and URLs stay empty.
  """
  @callback fetch_checkout(checkout_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Checkout.t()} | {:error, Splode.Error.t()}

  @doc "With `:checkout`. Reads one payment again from the provider, its source of truth."
  @callback fetch_payment(payment_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Payment.t()} | {:error, Splode.Error.t()}

  @doc "With `:expire`. Ends an open checkout so it can no longer be paid, and answers it after."
  @callback expire_checkout(checkout_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Checkout.t()} | {:error, Splode.Error.t()}

  @doc "With `:refund`. Gives money back on a payment and answers the refund as the provider made it."
  @callback refund(MishkaPay.Refund.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Refund.t()} | {:error, Splode.Error.t()}

  @doc "With `:refund_read`. Reads one refund again, with its status."
  @callback fetch_refund(refund_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Refund.t()} | {:error, Splode.Error.t()}

  @doc "With `:refund_read`. One page of refunds, newest first; `:payment_id` filters to one payment."
  @callback list_refunds(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:invoice`. Makes a draft bill with its items, and answers it."
  @callback create_invoice(MishkaPay.InvoiceDraft.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}

  @doc "With `:invoice`. Opens a draft for payment: it gets its number and can be paid."
  @callback finalize_invoice(invoice_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}

  @doc "With `:invoice`. Emails an open bill to its customer."
  @callback send_invoice(invoice_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}

  @doc "With `:invoice`. Charges an open bill now, or marks it paid outside the provider (`out_of_band: true`)."
  @callback pay_invoice(invoice_id :: String.t(), opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}

  @doc "With `:invoice`. Ends an open bill that should never have been sent."
  @callback void_invoice(invoice_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}

  @doc "With `:invoice`. Marks an open bill as one that will not be paid."
  @callback mark_invoice_uncollectible(invoice_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}

  @doc "With `:invoice`. Deletes a draft bill."
  @callback delete_invoice(invoice_id :: String.t(), MishkaPay.Credentials.t()) ::
              :ok | {:error, Splode.Error.t()}

  @doc """
  With `:event_list`. One page of the provider's events, newest first: `:since` (a `DateTime`)
  and `:types` (a list of event types) filter them.
  """
  @callback list_events(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:customer`. One page of customers that match every filter given: `:email`, `:name`,
  `:reference` (the host's own id kept on the customer).
  """
  @callback search_customers(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:subscription`. The bill a subscription will make next, as the provider counts it now."
  @callback upcoming_invoice(subscription_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}

  @doc "With `:subscription`. Reads one subscription again from the provider."
  @callback fetch_subscription(subscription_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Subscription.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:subscription`. Cancels a subscription `:now`, or at the end of the period paid for
  (`:period_end`), and answers it as the provider has it after.
  """
  @callback cancel_subscription(
              subscription_id :: String.t(),
              at :: :now | :period_end,
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.Subscription.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:subscription`. Takes back a cancel set for the period's end, so the subscription goes on,
  and answers it as the provider has it after.
  """
  @callback resume_subscription(subscription_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Subscription.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:subscription`. One page of invoices, newest first: those of `:subscription_id` or of
  `:customer_id`.
  """
  @callback list_invoices(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:subscription`. Reads one invoice, with its lines."
  @callback fetch_invoice(invoice_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:subscription_change`. Changes a subscription's plan or quantity as the change says,
  bills the difference its way, and answers the subscription after.
  """
  @callback change_subscription(MishkaPay.SubscriptionChange.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Subscription.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:subscription_change`. The invoice the change would make, with its proration lines,
  without changing anything.
  """
  @callback preview_subscription_change(
              MishkaPay.SubscriptionChange.t(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:subscription_change`. Pauses collecting a subscription's payments: `:behavior` says
  what happens to its invoices meanwhile, `:resumes_at` when collection starts again by itself.
  """
  @callback pause_collection(
              subscription_id :: String.t(),
              opts :: keyword(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.Subscription.t()} | {:error, Splode.Error.t()}

  @doc "With `:subscription_change`. Collects a paused subscription's payments again."
  @callback resume_collection(subscription_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Subscription.t()} | {:error, Splode.Error.t()}

  @doc "With `:payment_list`. One page of payments, newest first; only `:customer_id`'s when given."
  @callback list_payments(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:customer`. Makes a customer at the provider and answers it with its `:id`."
  @callback create_customer(MishkaPay.Customer.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Customer.t()} | {:error, Splode.Error.t()}

  @doc "With `:customer`. Reads one customer again."
  @callback fetch_customer(customer_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Customer.t()} | {:error, Splode.Error.t()}

  @doc "With `:customer`. Changes the fields set on the customer whose `:id` it carries."
  @callback update_customer(MishkaPay.Customer.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Customer.t()} | {:error, Splode.Error.t()}

  @doc "With `:customer`. One page of customers, newest first; only those with `:email` when given."
  @callback list_customers(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:portal`. Opens the provider's billing page for a customer and answers its `:url`."
  @callback portal_session(MishkaPay.PortalSession.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.PortalSession.t()} | {:error, Splode.Error.t()}

  @doc "With `:discount`. Makes a coupon and answers it with its `:id`."
  @callback create_coupon(MishkaPay.Coupon.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Coupon.t()} | {:error, Splode.Error.t()}

  @doc "With `:discount`. Reads one coupon again."
  @callback fetch_coupon(coupon_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Coupon.t()} | {:error, Splode.Error.t()}

  @doc "With `:discount`. One page of coupons, newest first."
  @callback list_coupons(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:discount`. Removes a coupon so it can no longer be applied."
  @callback delete_coupon(coupon_id :: String.t(), MishkaPay.Credentials.t()) ::
              :ok | {:error, Splode.Error.t()}

  @doc "With `:discount`. Makes a promotion code for a coupon and answers it with its `:id`."
  @callback create_promotion_code(MishkaPay.PromotionCode.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.PromotionCode.t()} | {:error, Splode.Error.t()}

  @doc "With `:discount`. Reads one promotion code again."
  @callback fetch_promotion_code(promotion_code_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.PromotionCode.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:discount`. One page of promotion codes, newest first; only those with `:code`, of
  `:coupon_id`, or `:active` when given.
  """
  @callback list_promotion_codes(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:catalog`. Makes a product and answers it with its `:id`."
  @callback create_product(MishkaPay.Product.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Product.t()} | {:error, Splode.Error.t()}

  @doc "With `:catalog`. Reads one product again."
  @callback fetch_product(product_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Product.t()} | {:error, Splode.Error.t()}

  @doc "With `:catalog`. Changes the fields set on the product whose `:id` it carries."
  @callback update_product(MishkaPay.Product.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Product.t()} | {:error, Splode.Error.t()}

  @doc "With `:catalog`. One page of products, newest first; only `:active` ones when given."
  @callback list_products(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:catalog`. Makes a price of a product (`:product_id`) and answers it with its `:id`."
  @callback create_price(MishkaPay.Price.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Price.t()} | {:error, Splode.Error.t()}

  @doc "With `:catalog`. Reads one price again."
  @callback fetch_price(price_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Price.t()} | {:error, Splode.Error.t()}

  @doc "With `:catalog`. Changes whether a price is on sale (`:active`), and its metadata."
  @callback update_price(MishkaPay.Price.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Price.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:catalog`. One page of prices, newest first; only those of `:product_id`, with
  `:lookup_key`, or `:active` when given.
  """
  @callback list_prices(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:dispute`. Reads one dispute."
  @callback fetch_dispute(dispute_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Dispute.t()} | {:error, Splode.Error.t()}

  @doc "With `:dispute`. One page of disputes, newest first; only `:payment_id`'s when given."
  @callback list_disputes(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:dispute`. Adds evidence to a dispute, and sends it with `:submit`."
  @callback update_dispute(MishkaPay.DisputeEvidence.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Dispute.t()} | {:error, Splode.Error.t()}

  @doc "With `:dispute`. Accepts the loss: the dispute closes as lost."
  @callback accept_dispute(dispute_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Dispute.t()} | {:error, Splode.Error.t()}

  @doc "With `:payment_link`. Makes a payment link and answers it with its `:id` and `:url`."
  @callback create_payment_link(MishkaPay.PaymentLink.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.PaymentLink.t()} | {:error, Splode.Error.t()}

  @doc "With `:payment_link`. Reads one payment link again."
  @callback fetch_payment_link(payment_link_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.PaymentLink.t()} | {:error, Splode.Error.t()}

  @doc "With `:payment_link`. One page of payment links, newest first; only `:active` ones when given."
  @callback list_payment_links(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:payment_link`. Changes the options set on a link (`:active` and the rest); its prices stay."
  @callback update_payment_link(MishkaPay.PaymentLink.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.PaymentLink.t()} | {:error, Splode.Error.t()}

  @doc "With `:discount`. Turns a promotion code off or on again (`:active`), and its metadata."
  @callback update_promotion_code(MishkaPay.PromotionCode.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.PromotionCode.t()} | {:error, Splode.Error.t()}

  @doc "With `:usage`. Makes a meter that counts usage reported under its event name."
  @callback create_meter(MishkaPay.Meter.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Meter.t()} | {:error, Splode.Error.t()}

  @doc "With `:usage`. One page of meters; only those of `:status` (`:active`, `:inactive`) when given."
  @callback list_meters(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:usage`. Turns a meter off: it takes no more usage and no new price."
  @callback deactivate_meter(meter_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Meter.t()} | {:error, Splode.Error.t()}

  @doc "With `:usage`. Reports one use by a customer, once for each reference."
  @callback report_usage(MishkaPay.Usage.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Usage.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:usage`. What a meter counted for `:customer_id` from `:from` to `:to` (both
  `DateTime`, `:to` after `:from`).
  """
  @callback usage_summary(meter_id :: String.t(), opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.UsageSummary.t()} | {:error, Splode.Error.t()}

  @doc "With `:entitlement`. Makes a feature a product can give."
  @callback create_feature(MishkaPay.Feature.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Feature.t()} | {:error, Splode.Error.t()}

  @doc "With `:entitlement`. Attaches a feature to a catalog product, and answers the feature."
  @callback attach_feature(
              product_id :: String.t(),
              feature_id :: String.t(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.Feature.t()} | {:error, Splode.Error.t()}

  @doc "With `:entitlement`. One page of the features `:customer_id` may use now."
  @callback list_entitlements(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:balance`. The seller's balance, available and pending, in each currency."
  @callback fetch_balance(MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Balance.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:balance`. One page of the balance's movements, newest first; only those a `:payout_id`
  paid out, or of `:type`, when given.
  """
  @callback list_balance_transactions(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:customer_balance`. Changes a customer's balance: below zero gives credit."
  @callback adjust_customer_balance(
              MishkaPay.CustomerBalanceTransaction.t(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.CustomerBalanceTransaction.t()} | {:error, Splode.Error.t()}

  @doc "With `:customer_balance`. One page of the changes to `:customer_id`'s balance, newest first."
  @callback list_customer_balance(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:webhook`. Checks a provider's signed message (the raw body and headers as they came) with
  the tenant's webhook secret and answers it as a `MishkaPay.Event`, or a
  `MishkaPay.Errors.BadSignature` error.
  """
  @callback verify_webhook(
              payload :: binary(),
              headers :: [{String.t(), String.t()}],
              MishkaPay.Credentials.t()
            ) ::
              {:ok, MishkaPay.Event.t()} | {:error, Splode.Error.t()}

  @doc """
  Optional. Whether the provider takes `keys`, with one read call that changes nothing
  (`MishkaPay.Check`).
  """
  @callback check_keys(MishkaPay.Credentials.t()) :: :ok | {:error, Splode.Error.t()}

  @optional_callbacks offered?: 0,
                      check_keys: 1,
                      checkout: 2,
                      fetch_checkout: 2,
                      fetch_payment: 2,
                      expire_checkout: 2,
                      refund: 2,
                      fetch_refund: 2,
                      search_customers: 2,
                      upcoming_invoice: 2,
                      list_events: 2,
                      create_invoice: 2,
                      finalize_invoice: 2,
                      send_invoice: 2,
                      pay_invoice: 3,
                      void_invoice: 2,
                      mark_invoice_uncollectible: 2,
                      delete_invoice: 2,
                      list_refunds: 2,
                      fetch_subscription: 2,
                      cancel_subscription: 3,
                      resume_subscription: 2,
                      list_invoices: 2,
                      fetch_invoice: 2,
                      change_subscription: 2,
                      preview_subscription_change: 2,
                      pause_collection: 3,
                      resume_collection: 2,
                      create_customer: 2,
                      fetch_customer: 2,
                      update_customer: 2,
                      list_customers: 2,
                      portal_session: 2,
                      create_coupon: 2,
                      fetch_coupon: 2,
                      list_coupons: 2,
                      delete_coupon: 2,
                      create_promotion_code: 2,
                      fetch_promotion_code: 2,
                      list_promotion_codes: 2,
                      update_promotion_code: 2,
                      list_payments: 2,
                      create_product: 2,
                      fetch_product: 2,
                      update_product: 2,
                      list_products: 2,
                      create_price: 2,
                      fetch_price: 2,
                      update_price: 2,
                      list_prices: 2,
                      fetch_dispute: 2,
                      list_disputes: 2,
                      update_dispute: 2,
                      accept_dispute: 2,
                      create_payment_link: 2,
                      fetch_payment_link: 2,
                      list_payment_links: 2,
                      update_payment_link: 2,
                      create_meter: 2,
                      list_meters: 2,
                      deactivate_meter: 2,
                      report_usage: 2,
                      usage_summary: 3,
                      create_feature: 2,
                      attach_feature: 3,
                      list_entitlements: 2,
                      fetch_balance: 1,
                      list_balance_transactions: 2,
                      adjust_customer_balance: 2,
                      list_customer_balance: 2,
                      verify_webhook: 3

  @operations %{
    checkout: [checkout: 2, fetch_checkout: 2, fetch_payment: 2],
    expire: [expire_checkout: 2],
    payment_list: [list_payments: 2],
    refund: [refund: 2],
    refund_read: [fetch_refund: 2, list_refunds: 2],
    subscription: [
      fetch_subscription: 2,
      cancel_subscription: 3,
      resume_subscription: 2,
      list_invoices: 2,
      fetch_invoice: 2,
      upcoming_invoice: 2
    ],
    subscription_change: [
      change_subscription: 2,
      preview_subscription_change: 2,
      pause_collection: 3,
      resume_collection: 2
    ],
    invoice: [
      create_invoice: 2,
      finalize_invoice: 2,
      send_invoice: 2,
      pay_invoice: 3,
      void_invoice: 2,
      mark_invoice_uncollectible: 2,
      delete_invoice: 2
    ],
    customer: [
      create_customer: 2,
      fetch_customer: 2,
      update_customer: 2,
      list_customers: 2,
      search_customers: 2
    ],
    portal: [portal_session: 2],
    discount: [
      create_coupon: 2,
      fetch_coupon: 2,
      list_coupons: 2,
      delete_coupon: 2,
      create_promotion_code: 2,
      fetch_promotion_code: 2,
      list_promotion_codes: 2,
      update_promotion_code: 2
    ],
    catalog: [
      create_product: 2,
      fetch_product: 2,
      update_product: 2,
      list_products: 2,
      create_price: 2,
      fetch_price: 2,
      update_price: 2,
      list_prices: 2
    ],
    event_list: [list_events: 2],
    dispute: [fetch_dispute: 2, list_disputes: 2, update_dispute: 2, accept_dispute: 2],
    payment_link: [
      create_payment_link: 2,
      fetch_payment_link: 2,
      list_payment_links: 2,
      update_payment_link: 2
    ],
    usage: [
      create_meter: 2,
      list_meters: 2,
      deactivate_meter: 2,
      report_usage: 2,
      usage_summary: 3
    ],
    entitlement: [create_feature: 2, attach_feature: 3, list_entitlements: 2],
    balance: [fetch_balance: 1, list_balance_transactions: 2],
    customer_balance: [adjust_customer_balance: 2, list_customer_balance: 2],
    webhook: [verify_webhook: 3]
  }

  @options [:id, :label, :capabilities, :priority]

  @doc false
  defmacro __using__(opts) do
    check_options!(opts)
    id = Keyword.fetch!(opts, :id)
    label = Keyword.fetch!(opts, :label)
    capabilities = Keyword.get(opts, :capabilities, [])
    priority = Keyword.get(opts, :priority, 50)

    check_id!(id)
    check_label!(label)
    check_capabilities!(capabilities)
    check_priority!(priority)

    quote do
      use MishkaInstaller.Event.Hook,
        event: unquote(Events.providers()),
        initial: %{priority: unquote(priority)}

      @behaviour MishkaPay.Provider
      @before_compile MishkaPay.Provider
      @mishka_pay_capabilities unquote(capabilities)

      @impl true
      def call(%{providers: providers} = state) when is_list(providers),
        do: {:reply, %{state | providers: providers ++ [__MODULE__]}}

      def call(state), do: {:reply, state}

      @impl MishkaPay.Provider
      def id, do: unquote(id)

      @impl MishkaPay.Provider
      def label, do: unquote(label)

      @impl MishkaPay.Provider
      def capabilities, do: unquote(capabilities)
    end
  end

  # A capability is a promise: a provider that declares one and lacks its functions does not
  # compile, so it can never be offered and then fail at the first payment.
  @doc false
  defmacro __before_compile__(env) do
    missing =
      for capability <- Module.get_attribute(env.module, :mishka_pay_capabilities),
          {name, arity} <- Map.get(@operations, capability, []),
          not Module.defines?(env.module, {name, arity}, :def),
          do: "#{name}/#{arity} (for #{inspect(capability)})"

    case missing do
      [] ->
        :ok

      _missing ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "#{inspect(env.module)} declares capabilities without " <> Enum.join(missing, ", ")
    end

    nil
  end

  @doc "Every capability a provider may declare."
  @spec capabilities() :: [capability()]
  def capabilities, do: @capabilities

  @doc "Lists what a capability asks a provider to define, such as `[checkout: 2, fetch_payment: 2]`."
  @spec operations(capability()) :: keyword(pos_integer())
  def operations(capability), do: Map.get(@operations, capability, [])

  @doc """
  The offered provider `id` when it has `capability`, or an `UnknownProvider` or `Unsupported`
  error.
  """
  @spec capable(String.t(), capability()) :: {:ok, module()} | {:error, Splode.Error.t()}
  def capable(id, capability) do
    with {:ok, provider} <- fetch(id) do
      case capability in provider.capabilities() do
        true -> {:ok, provider}
        false -> {:error, Errors.Unsupported.exception(provider: id, operation: capability)}
      end
    end
  end

  @doc "Every installed provider, the first of each id. None when the event cannot run."
  @spec all() :: [module()]
  def all do
    case installed() do
      {:ok, providers} -> providers
      {:error, :cannot_run} -> []
    end
  end

  @doc "The installed providers this installation offers: every one, unless its `offered?/0` says not."
  @spec offered() :: [module()]
  def offered, do: offered_of(all())

  @doc "The offered provider whose id is `id`."
  @spec fetch(String.t()) :: {:ok, module()} | {:error, Splode.Error.t()}
  def fetch(id) when is_binary(id) do
    case installed() do
      {:ok, providers} -> providers |> offered_of() |> Enum.find(&(&1.id() == id)) |> found(id)
      {:error, :cannot_run} -> unknown(id, :cannot_run)
    end
  end

  defp found(nil, id), do: unknown(id, :not_installed)
  defp found(provider, _id), do: {:ok, provider}

  defp unknown(id, reason),
    do: {:error, Errors.UnknownProvider.exception(provider: id, reason: reason)}

  defp installed do
    case Hook.call(Events.providers(), %{providers: []}, cannot_run: :cannot_run) do
      %{providers: providers} when is_list(providers) ->
        {:ok, providers |> Enum.filter(&provider?/1) |> Enum.uniq_by(& &1.id())}

      :cannot_run ->
        {:error, :cannot_run}

      _not_an_answer ->
        {:ok, []}
    end
  end

  # Every required callback, not one picked as a sample: a module missing one would be offered and
  # then fail when that one is called.
  defp provider?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and __MODULE__ in behaviours(module) and
      Enum.all?(
        __MODULE__.behaviour_info(:callbacks) -- __MODULE__.behaviour_info(:optional_callbacks),
        fn {name, arity} -> function_exported?(module, name, arity) end
      )
  end

  defp provider?(_other), do: false

  defp offered_of(providers), do: Enum.filter(providers, &offered?/1)

  # One provider whose `offered?/0` raises is left out, and the others are still offered.
  defp offered?(provider) do
    not function_exported?(provider, :offered?, 0) or provider.offered?() == true
  rescue
    exception ->
      Logger.warning(
        "mishka_pay: #{inspect(provider)}.offered?/0 raised and is not offered: " <>
          Exception.message(exception)
      )

      false
  end

  defp behaviours(module),
    do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

  defp check_options!(opts) do
    case Keyword.keys(opts) -- @options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown MishkaPay.Provider options: #{inspect(unknown)}"
    end
  end

  defp check_id!(id) when is_binary(id) do
    case Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, id) do
      true ->
        :ok

      false ->
        raise ArgumentError,
              "a provider id is lowercase letters, digits and _, got: #{inspect(id)}"
    end
  end

  defp check_id!(_id),
    do: raise(ArgumentError, "a provider id is a literal string, such as \"acme\"")

  defp check_label!(label) when is_binary(label) and label != "", do: :ok
  defp check_label!(_label), do: raise(ArgumentError, "a provider label is a literal string")

  defp check_capabilities!(capabilities) when is_list(capabilities) do
    case {Enum.reject(capabilities, &(&1 in @capabilities)),
          capabilities -- Enum.uniq(capabilities)} do
      {[], []} ->
        :ok

      {[], twice} ->
        raise ArgumentError, "provider capabilities listed twice: #{inspect(twice)}"

      {unknown, _twice} ->
        raise ArgumentError, "unknown provider capabilities: #{inspect(unknown)}"
    end
  end

  defp check_capabilities!(_other),
    do: raise(ArgumentError, "provider capabilities is a literal list of atoms")

  defp check_priority!(priority) when is_integer(priority) and priority >= 0, do: :ok

  defp check_priority!(_other),
    do: raise(ArgumentError, "a provider priority is a whole number, 0 or more")
end

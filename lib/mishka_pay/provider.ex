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
    * `:embedded_checkout`: nothing more; `checkout/2` also takes `ui_mode: :embedded`;
    * `:capture`: `capture_payment/3`, `cancel_payment/2` (`checkout/2` also takes
      `capture: :manual`);
    * `:expire`: `expire_checkout/2`;
    * `:intent`: `create_payment_intent/2`, `fetch_payment_intent/2`, `update_payment_intent/2`,
      `confirm_payment_intent/3`, `cancel_payment_intent/2`, `create_setup_intent/2`,
      `fetch_setup_intent/2`, `confirm_setup_intent/3`, `cancel_setup_intent/2`;
    * `:payment_list`: `list_payments/2`;
    * `:refund`: `refund/2`;
    * `:refund_read`: `fetch_refund/2`, `list_refunds/2`;
    * `:subscription`: `fetch_subscription/2`, `cancel_subscription/3`, `resume_subscription/2`,
      `list_invoices/2`, `fetch_invoice/2` and `upcoming_invoice/2` (a subscription starts with a checkout in
      `mode: :subscription`);
    * `:subscription_change`: `change_subscription/2`, `preview_subscription_change/2`,
      `pause_collection/3`, `resume_collection/2`;
    * `:subscription_list`: `list_subscriptions/2`, `search_subscriptions/2`;
    * `:subscription_schedule`: `create_subscription_schedule/2`,
      `fetch_subscription_schedule/2`, `list_subscription_schedules/2`,
      `update_subscription_schedule/2`, `release_subscription_schedule/2`,
      `cancel_subscription_schedule/3`;
    * `:invoice`: `create_invoice/2`, `finalize_invoice/2`, `send_invoice/2`, `pay_invoice/3`,
      `void_invoice/2`, `mark_invoice_uncollectible/2`, `delete_invoice/2`;
    * `:invoice_item`: `create_invoice_item/2`, `update_invoice_item/2`, `delete_invoice_item/2`,
      `list_invoice_items/2`;
    * `:credit_note`: `create_credit_note/2`, `preview_credit_note/2`, `fetch_credit_note/2`,
      `void_credit_note/2`, `list_credit_notes/2`, `list_credit_note_lines/3`;
    * `:customer`: `create_customer/2`, `fetch_customer/2`, `update_customer/2`, `list_customers/2`,
      `search_customers/2`, `delete_customer/2`;
    * `:tax_id`: `create_tax_id/2`, `list_tax_ids/2`, `delete_tax_id/3`;
    * `:tax`: `calculate_tax/2`, `record_tax/3`;
    * `:tax_rate`: `create_tax_rate/2`, `fetch_tax_rate/2`, `update_tax_rate/2`,
      `list_tax_rates/2` (and a line's or a bill's `:tax_rate_ids`);
    * `:tax_setup`: `create_tax_registration/2`, `list_tax_registrations/2`,
      `expire_tax_registration/3`, `fetch_tax_settings/1`, `update_tax_settings/2`;
    * `:shipping`: `create_shipping_rate/2`, `list_shipping_rates/2` (and a checkout's
      `:shipping_countries` and `:shipping_rates`);
    * `:portal`: `portal_session/2`, and the portal's setups: `create_portal_configuration/2`,
      `update_portal_configuration/2`, `fetch_portal_configuration/2`,
      `list_portal_configurations/2`;
    * `:payment_method`: `list_payment_methods/2`, `fetch_payment_method/2`,
      `detach_payment_method/2`, `set_default_payment_method/3` (a checkout in `mode: :setup`
      saves one);
    * `:discount`: coupons and promotion codes (`create_coupon/2` and the rest);
    * `:catalog`: products and prices (`create_product/2` and the rest);
    * `:payment_link`: `create_payment_link/2`, `fetch_payment_link/2`, `list_payment_links/2`,
      `update_payment_link/2`;
    * `:dispute`: `fetch_dispute/2`, `list_disputes/2`, `update_dispute/2`, `accept_dispute/2`;
    * `:fraud`: `fetch_fraud_warning/2`, `list_fraud_warnings/2`, `fetch_fraud_review/2`,
      `list_fraud_reviews/2`, `approve_fraud_review/2`;
    * `:file`: `upload_file/2`, `fetch_file/2`, `file_link/3`;
    * `:usage`: `create_meter/2`, `fetch_meter/2`, `update_meter/2`, `list_meters/2`,
      `deactivate_meter/2`, `reactivate_meter/2`, `report_usage/2`, `cancel_usage/2`,
      `usage_summary/3`;
    * `:entitlement`: `create_feature/2`, `attach_feature/3`, `list_entitlements/2`;
    * `:balance`: `fetch_balance/1`, `list_balance_transactions/2`;
    * `:customer_balance`: `adjust_customer_balance/2`, `list_customer_balance/2`;
    * `:connect`: `create_connected_account/2`, `fetch_connected_account/3`,
      `update_connected_account/2`, `list_connected_accounts/2`, `close_connected_account/3`,
      `account_link/2`, `login_link/2`, `fetch_application_fee/2`, `list_application_fees/2`,
      `refund_application_fee/3` (and a checkout's `:application_fee`,
      `:application_fee_percent`, `:destination` and `:on_behalf_of`);
    * `:transfer`: `create_transfer/2`, `fetch_transfer/2`, `list_transfers/2`,
      `reverse_transfer/3`;
    * `:payout`: `create_payout/2`, `fetch_payout/2`, `list_payouts/2`, `cancel_payout/2`;
    * `:payout_schedule`: `fetch_payout_schedule/1`, `update_payout_schedule/2`;
    * `:payout_destination`: `list_payout_destinations/2`, `fetch_payout_destination/2`;
    * `:webhook`: `verify_webhook/3`;
    * `:event_list`: `list_events/2`;
    * `:raw_request`: `raw_request/2`.

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
    :embedded_checkout,
    :capture,
    :expire,
    :intent,
    :payment_list,
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
    :tax_rate,
    :tax_setup,
    :shipping,
    :portal,
    :payment_method,
    :discount,
    :catalog,
    :payment_link,
    :dispute,
    :fraud,
    :file,
    :usage,
    :entitlement,
    :balance,
    :customer_balance,
    :connect,
    :transfer,
    :payout,
    :payout_schedule,
    :payout_destination,
    :webhook,
    :event_list,
    :raw_request,
    :return_verify
  ]

  @typedoc """
  What a provider can do:

    * `:checkout`: sends the buyer to pay, or embeds a payment form.
    * `:embedded_checkout`: shows its checkout form inside the site's own page
      (`ui_mode: :embedded`).
    * `:capture`: holds the money on a card at checkout (`capture: :manual`), then takes it, all
      or part, or lets it go.
    * `:expire`: ends an open checkout before the buyer pays, so its stock is free again.
    * `:intent`: takes a payment, or saves a payment method, with its own card form inside the
      site's page (Stripe Elements), without a checkout page: the server makes the intent, the
      buyer's browser confirms it with its client secret, and the server reads, changes, confirms
      or cancels it.
    * `:payment_list`: lists past payments page by page.
    * `:refund`: gives money back on a payment.
    * `:refund_read`: reads a refund again, and lists refunds page by page.
    * `:subscription`: charges again on a schedule.
    * `:subscription_change`: changes a running subscription's plan or quantity with proration,
      previews what that bills, and pauses or resumes its collection.
    * `:subscription_list`: lists subscriptions page by page (by customer, status or price), and
      searches them by status, reference or metadata. A provider can run subscriptions without
      it: PayPal has no list of them.
    * `:subscription_schedule`: plans a subscription's changes ahead in phases (a new price on a
      date, a trial, an end after some periods), made from a running subscription or new, and
      changes, releases or cancels the plan.
    * `:invoice`: makes one-off bills for a customer, and opens, sends, settles or ends them.
    * `:invoice_item`: keeps charges on their own (add, change, remove, list) that wait for a
      customer's next bill, or go on a draft one. Apart from `:invoice`: a provider may bill
      without keeping charges between bills (PayPal's invoices hold their items only inside one).
    * `:credit_note`: takes back part or all of a finalized bill with a credit note (by amount or
      by line, refunded, credited to the customer's balance or settled outside), previews one,
      reads, lists and voids them.
    * `:customer`: keeps buyers (create, read, update, list, delete).
    * `:tax_id`: keeps a business buyer's tax ids (EU VAT and the rest) on its customer.
    * `:tax`: counts the tax on a sale made outside its checkout, and records the sale for the
      site's tax reports.
    * `:tax_rate`: keeps tax rates the seller sets by hand (a percentage, inclusive or on top,
      for a place), and adds them to the lines of its checkouts and bills. Apart from `:tax`: a
      provider may take fixed rates without counting any tax itself.
    * `:tax_setup`: keeps where the seller is registered to collect tax, and the site's tax
      settings (head office, the default tax code and behavior) that its tax counting uses.
      Apart from `:tax`: a provider that counts the tax as the merchant of record has no
      registrations of the seller's to keep.
    * `:shipping`: keeps shipping rates, and its checkout asks for a shipping address and
      charges the rate the buyer picks.
    * `:portal`: has a hosted page where a customer manages their own billing, and keeps setups
      of what buyers may do there.
    * `:payment_method`: keeps a customer's saved payment methods (read, list, take off, make
      the default), and saves one with a checkout in `mode: :setup`.
    * `:discount`: keeps coupons and the promotion codes buyers type.
    * `:catalog`: keeps products and their prices, so a checkout sells a price by its id.
    * `:payment_link`: makes pages that sell catalog prices to anyone who opens them.
    * `:dispute`: reads chargebacks and answers them with evidence, or accepts them.
    * `:fraud`: reads a card issuer's early fraud warnings, and the payments its fraud rules hold
      for review, which the seller lets through.
    * `:file`: keeps files, such as dispute evidence, and makes public links to them.
    * `:usage`: counts what customers use on meters, for prices billed by usage, and takes back
      a report sent by mistake.
    * `:entitlement`: attaches features to products and tells which ones a customer may use.
    * `:balance`: reads the seller's balance and the movements that made it.
    * `:customer_balance`: keeps a customer's store credit, taken off their next bills.
    * `:connect`: runs a platform of sellers: makes their connected accounts and the links that
      onboard them, acts for one when a tenant's keys name it (`:account_id`), takes the
      platform's cut of their sales (a checkout's `:application_fee`, `:destination`,
      `:on_behalf_of`) and gives it back.
    * `:transfer`: sends money from the platform's balance to a connected account, and takes it
      back.
    * `:payout`: pays an account's available balance out to its bank now, reads its payouts, and
      stops a pending one.
    * `:payout_schedule`: reads and sets when the balance is paid out by itself (interval, days,
      how long a payment's money waits) and what stays in it.
    * `:payout_destination`: reads the bank accounts and cards an account's payouts go to, with
      the bank's name and the last four digits.
    * `:webhook`: sends signed messages when something changes.
    * `:event_list`: lists the messages it sent, to deliver again those a site missed.
    * `:raw_request`: calls any path of its own API with the tenant's keys, for what Mishka Pay
      has no typed call for yet (`MishkaPay.request/1`).
    * `:return_verify`: has no webhook; the buyer comes back to a return URL and the payment is
      checked with a call to the provider.
  """
  @type capability ::
          :checkout
          | :embedded_checkout
          | :capture
          | :expire
          | :intent
          | :refund
          | :refund_read
          | :subscription
          | :subscription_change
          | :subscription_list
          | :subscription_schedule
          | :invoice
          | :invoice_item
          | :credit_note
          | :customer
          | :tax_id
          | :tax
          | :tax_rate
          | :tax_setup
          | :shipping
          | :portal
          | :payment_method
          | :discount
          | :catalog
          | :payment_link
          | :dispute
          | :fraud
          | :file
          | :usage
          | :entitlement
          | :balance
          | :customer_balance
          | :connect
          | :transfer
          | :payout
          | :payout_schedule
          | :payout_destination
          | :payment_list
          | :webhook
          | :event_list
          | :raw_request
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

  @doc """
  With `:capture`. Takes the money held on an `:authorized` payment: all of it, or `:amount`
  (a `Money` in the payment's currency) when given. The rest is let go. Answers the payment after.
  """
  @callback capture_payment(
              payment_id :: String.t(),
              opts :: keyword(),
              MishkaPay.Credentials.t()
            ) ::
              {:ok, MishkaPay.Payment.t()} | {:error, Splode.Error.t()}

  @doc "With `:capture`. Lets the money held on an `:authorized` payment go; it ends `:canceled`."
  @callback cancel_payment(payment_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Payment.t()} | {:error, Splode.Error.t()}

  @doc "With `:refund_read`. Reads one refund again, with its status."
  @callback fetch_refund(refund_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Refund.t()} | {:error, Splode.Error.t()}

  @doc "With `:refund_read`. One page of refunds, newest first; `:payment_id` filters to one payment."
  @callback list_refunds(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:invoice`. Makes a draft bill with its items, and answers it."
  @callback create_invoice(MishkaPay.Invoice.Draft.t(), MishkaPay.Credentials.t()) ::
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
  With `:invoice_item`. Adds a charge for `:customer_id`, on draft bill `:invoice_id` or waiting
  for the next bill, and answers it with its `:id`.
  """
  @callback create_invoice_item(MishkaPay.Invoice.Item.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Invoice.Item.t()} | {:error, Splode.Error.t()}

  @doc "With `:invoice_item`. Changes the fields set on the item whose `:id` it carries."
  @callback update_invoice_item(MishkaPay.Invoice.Item.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Invoice.Item.t()} | {:error, Splode.Error.t()}

  @doc "With `:invoice_item`. Removes an item that is not on a finalized bill."
  @callback delete_invoice_item(invoice_item_id :: String.t(), MishkaPay.Credentials.t()) ::
              :ok | {:error, Splode.Error.t()}

  @doc """
  With `:invoice_item`. One page of items, newest first; only those of `:customer_id`, on
  `:invoice_id`, or waiting for a bill (`pending: true`) when given.
  """
  @callback list_invoice_items(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:subscription_schedule`. Makes a schedule from `:subscription_id`, or for `:customer_id`
  with its `:phases`, and answers it with its `:id` and phase dates.
  """
  @callback create_subscription_schedule(
              MishkaPay.Subscription.Schedule.t(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.Subscription.Schedule.t()} | {:error, Splode.Error.t()}

  @doc "With `:subscription_schedule`. Reads one schedule again, with its phases."
  @callback fetch_subscription_schedule(schedule_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Subscription.Schedule.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:subscription_schedule`. One page of schedules, newest first; only `:customer_id`'s, or
  those not started yet (`scheduled: true`), when given.
  """
  @callback list_subscription_schedules(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:subscription_schedule`. Changes what the schedule carries (`:phases`, `:end_behavior`,
  `:metadata`) on the schedule whose `:id` it carries.
  """
  @callback update_subscription_schedule(
              MishkaPay.Subscription.Schedule.t(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.Subscription.Schedule.t()} | {:error, Splode.Error.t()}

  @doc "With `:subscription_schedule`. Ends the schedule; its subscription goes on alone."
  @callback release_subscription_schedule(schedule_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Subscription.Schedule.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:subscription_schedule`. Ends the schedule and its subscription now; `:invoice_now` bills
  what is left, `:prorate` credits time not used.
  """
  @callback cancel_subscription_schedule(
              schedule_id :: String.t(),
              opts :: keyword(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.Subscription.Schedule.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:credit_note`. Makes a credit note on `:invoice_id` for `:amount` or `:lines`, and
  answers it with its `:id`.
  """
  @callback create_credit_note(MishkaPay.CreditNote.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.CreditNote.t()} | {:error, Splode.Error.t()}

  @doc "With `:credit_note`. The note `create_credit_note/2` would make, without making it."
  @callback preview_credit_note(MishkaPay.CreditNote.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.CreditNote.t()} | {:error, Splode.Error.t()}

  @doc "With `:credit_note`. Reads one credit note again, with its lines."
  @callback fetch_credit_note(credit_note_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.CreditNote.t()} | {:error, Splode.Error.t()}

  @doc "With `:credit_note`. Voids an issued credit note, and answers it after."
  @callback void_credit_note(credit_note_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.CreditNote.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:credit_note`. One page of credit notes, newest first; only those on `:invoice_id` or of
  `:customer_id` when given.
  """
  @callback list_credit_notes(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:credit_note`. One page of a credit note's lines (`MishkaPay.CreditNote.Lines`)."
  @callback list_credit_note_lines(
              credit_note_id :: String.t(),
              opts :: keyword(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:event_list`. One page of the provider's events, newest first: `:since` (a `DateTime`)
  and `:types` (a list of event types) filter them.
  """
  @callback list_events(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:customer`. One page of customers that match every filter given: `:email`, `:name`,
  `:reference` (the host's own id kept on the customer); `:api`, at a provider with two customer
  APIs, the one the answers are named by.
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
  @callback change_subscription(MishkaPay.Subscription.Change.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Subscription.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:subscription_change`. The invoice the change would make, with its proration lines,
  without changing anything.
  """
  @callback preview_subscription_change(
              MishkaPay.Subscription.Change.t(),
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

  @doc """
  With `:subscription_list`. One page of subscriptions, newest first; only those of
  `:customer_id`, charging `:price_id`, or in `:status` (a `MishkaPay.Subscription` status, or
  `:all`) when given.
  """
  @callback list_subscriptions(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:subscription_list`. One page of subscriptions that match every filter given:
  `:status`, `:reference` (the caller's own id from the checkout), `:metadata` (pairs that must
  all match).
  """
  @callback search_subscriptions(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:payment_list`. One page of payments, newest first; only `:customer_id`'s when given."
  @callback list_payments(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:customer`. Makes a customer at the provider and answers it with its `:id`, on the
  customer's `:api`, else the tenant's `:customer_api`, at a provider with two.
  """
  @callback create_customer(MishkaPay.Customer.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Customer.t()} | {:error, Splode.Error.t()}

  @doc "With `:customer`. Reads one customer again, on the API its id belongs to."
  @callback fetch_customer(customer_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Customer.t()} | {:error, Splode.Error.t()}

  @doc "With `:customer`. Changes the fields set on the customer whose `:id` it carries."
  @callback update_customer(MishkaPay.Customer.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Customer.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:customer`. One page of customers, newest first; only those with `:email` when given, on
  `:api`, else the tenant's `:customer_api`, at a provider with two.
  """
  @callback list_customers(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:customer`. Deletes a customer at the provider for good, as a person's erase request
  asks: what the provider keeps on them (saved cards, running subscriptions) goes with it.
  """
  @callback delete_customer(customer_id :: String.t(), MishkaPay.Credentials.t()) ::
              :ok | {:error, Splode.Error.t()}

  @doc "With `:tax_id`. Adds a tax id to the customer it names (`:customer_id`), and answers it."
  @callback create_tax_id(MishkaPay.Customer.TaxId.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Customer.TaxId.t()} | {:error, Splode.Error.t()}

  @doc "With `:tax_id`. One page of the tax ids of customer `:customer_id`."
  @callback list_tax_ids(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:tax`. Counts the tax on the calculation's lines and shipping for the buyer's address or
  customer, and answers it with its `:id`, totals and the tax of each line.
  """
  @callback calculate_tax(MishkaPay.TaxCalculation.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.TaxCalculation.t()} | {:error, Splode.Error.t()}

  @doc "With `:tax`. Records the sale of a calculation under the caller's `reference`, for the tax reports."
  @callback record_tax(
              calculation_id :: String.t(),
              reference :: String.t(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.TaxCalculation.Transaction.t()} | {:error, Splode.Error.t()}

  @doc "With `:shipping`. Makes a shipping rate and answers it with its `:id`."
  @callback create_shipping_rate(MishkaPay.ShippingRate.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.ShippingRate.t()} | {:error, Splode.Error.t()}

  @doc "With `:shipping`. One page of shipping rates, newest first; only `:active` ones when given."
  @callback list_shipping_rates(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:intent`. Makes a payment intent for the site's own card form, and answers it with its
  `:id` and `:client_secret`.
  """
  @callback create_payment_intent(MishkaPay.PaymentIntent.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.PaymentIntent.t()} | {:error, Splode.Error.t()}

  @doc "With `:intent`. Reads one payment intent, with its status."
  @callback fetch_payment_intent(payment_intent_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.PaymentIntent.t()} | {:error, Splode.Error.t()}

  @doc "With `:intent`. Changes payment intent `:id` before it is paid: only the fields set."
  @callback update_payment_intent(MishkaPay.PaymentIntent.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.PaymentIntent.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:intent`. Confirms a payment intent on the server, with `:payment_method_id` and the
  `:return_url` a payment method's own page sends the buyer back to.
  """
  @callback confirm_payment_intent(
              payment_intent_id :: String.t(),
              opts :: keyword(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.PaymentIntent.t()} | {:error, Splode.Error.t()}

  @doc "With `:intent`. Cancels a payment intent that is not paid, or lets a held one go."
  @callback cancel_payment_intent(payment_intent_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.PaymentIntent.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:intent`. Makes a setup intent that saves a payment method with the site's own form, and
  answers it with its `:id` and `:client_secret`.
  """
  @callback create_setup_intent(MishkaPay.SetupIntent.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.SetupIntent.t()} | {:error, Splode.Error.t()}

  @doc "With `:intent`. Reads one setup intent, with its status."
  @callback fetch_setup_intent(setup_intent_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.SetupIntent.t()} | {:error, Splode.Error.t()}

  @doc "With `:intent`. Confirms a setup intent on the server, as `confirm_payment_intent/3`."
  @callback confirm_setup_intent(
              setup_intent_id :: String.t(),
              opts :: keyword(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.SetupIntent.t()} | {:error, Splode.Error.t()}

  @doc "With `:intent`. Cancels a setup intent that has not succeeded."
  @callback cancel_setup_intent(setup_intent_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.SetupIntent.t()} | {:error, Splode.Error.t()}

  @doc "With `:tax_rate`. Makes a tax rate, and answers it with its `:id`."
  @callback create_tax_rate(MishkaPay.TaxRate.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.TaxRate.t()} | {:error, Splode.Error.t()}

  @doc "With `:tax_rate`. Reads one tax rate, archived or not."
  @callback fetch_tax_rate(tax_rate_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.TaxRate.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:tax_rate`. Changes tax rate `:id`: only the fields set, never its percentage or whether it
  is inclusive.
  """
  @callback update_tax_rate(MishkaPay.TaxRate.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.TaxRate.t()} | {:error, Splode.Error.t()}

  @doc "With `:tax_rate`. One page of tax rates, newest first; `:active` and `:inclusive` filter."
  @callback list_tax_rates(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:tax_setup`. Registers the seller to collect tax in a country, and answers it."
  @callback create_tax_registration(
              MishkaPay.TaxSettings.Registration.t(),
              MishkaPay.Credentials.t()
            ) ::
              {:ok, MishkaPay.TaxSettings.Registration.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:tax_setup`. One page of the seller's tax registrations; `:status` is `:active` (the
  default), `:scheduled`, `:expired` or `:all`.
  """
  @callback list_tax_registrations(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:tax_setup`. Ends a tax registration `at` a time (`nil`: now), and answers it."
  @callback expire_tax_registration(
              registration_id :: String.t(),
              at :: DateTime.t() | nil,
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.TaxSettings.Registration.t()} | {:error, Splode.Error.t()}

  @doc "With `:tax_setup`. Reads the site's tax settings."
  @callback fetch_tax_settings(MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.TaxSettings.t()} | {:error, Splode.Error.t()}

  @doc "With `:tax_setup`. Changes the site's tax settings: only the fields set."
  @callback update_tax_settings(MishkaPay.TaxSettings.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.TaxSettings.t()} | {:error, Splode.Error.t()}

  @doc "With `:tax_id`. Removes one tax id from a customer."
  @callback delete_tax_id(
              customer_id :: String.t(),
              tax_id_id :: String.t(),
              MishkaPay.Credentials.t()
            ) :: :ok | {:error, Splode.Error.t()}

  @doc "With `:portal`. Opens the provider's billing page for a customer and answers its `:url`."
  @callback portal_session(MishkaPay.PortalSession.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.PortalSession.t()} | {:error, Splode.Error.t()}

  @doc "With `:portal`. Makes a portal setup and answers it with its `:id`."
  @callback create_portal_configuration(
              MishkaPay.PortalSession.Configuration.t(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.PortalSession.Configuration.t()} | {:error, Splode.Error.t()}

  @doc "With `:portal`. Changes the fields set on the portal setup whose `:id` it carries."
  @callback update_portal_configuration(
              MishkaPay.PortalSession.Configuration.t(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.PortalSession.Configuration.t()} | {:error, Splode.Error.t()}

  @doc "With `:portal`. Reads one portal setup."
  @callback fetch_portal_configuration(configuration_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.PortalSession.Configuration.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:portal`. One page of portal setups, newest first; only `:active` ones, or the
  `:default` one, when given.
  """
  @callback list_portal_configurations(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:payment_method`. One page of a customer's saved payment methods (`:customer_id`)."
  @callback list_payment_methods(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:payment_method`. Reads one saved payment method again."
  @callback fetch_payment_method(payment_method_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Customer.PaymentMethod.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:payment_method`. Takes a payment method off its customer for good, and answers it
  after, with no `:customer_id`.
  """
  @callback detach_payment_method(payment_method_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Customer.PaymentMethod.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:payment_method`. Makes a saved payment method the one a customer's invoices and
  subscriptions charge, and answers the customer after (`:default_payment_method`).
  """
  @callback set_default_payment_method(
              customer_id :: String.t(),
              payment_method_id :: String.t(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.Customer.t()} | {:error, Splode.Error.t()}

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
  @callback create_promotion_code(MishkaPay.Coupon.PromotionCode.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Coupon.PromotionCode.t()} | {:error, Splode.Error.t()}

  @doc "With `:discount`. Reads one promotion code again."
  @callback fetch_promotion_code(promotion_code_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Coupon.PromotionCode.t()} | {:error, Splode.Error.t()}

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
  @callback update_dispute(MishkaPay.Dispute.Evidence.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Dispute.t()} | {:error, Splode.Error.t()}

  @doc "With `:dispute`. Accepts the loss: the dispute closes as lost."
  @callback accept_dispute(dispute_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Dispute.t()} | {:error, Splode.Error.t()}

  @doc "With `:fraud`. Reads one early fraud warning."
  @callback fetch_fraud_warning(warning_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Payment.FraudWarning.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:fraud`. One page of early fraud warnings, newest first; only those about `:payment_id`
  or `:charge_id` when given.
  """
  @callback list_fraud_warnings(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:fraud`. Reads one review, open or closed."
  @callback fetch_fraud_review(review_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Payment.FraudReview.t()} | {:error, Splode.Error.t()}

  @doc "With `:fraud`. One page of the reviews still open, newest first."
  @callback list_fraud_reviews(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:fraud`. Lets an open review's payment through, and answers the review closed."
  @callback approve_fraud_review(review_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Payment.FraudReview.t()} | {:error, Splode.Error.t()}

  @doc "With `:file`. Uploads a file, after checking the provider takes its type and size."
  @callback upload_file(MishkaPay.File.Upload.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.File.t()} | {:error, Splode.Error.t()}

  @doc "With `:file`. Reads one file the provider keeps."
  @callback fetch_file(file_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.File.t()} | {:error, Splode.Error.t()}

  @doc "With `:file`. Makes a public link to a file; `:expires_at` ends it."
  @callback file_link(file_id :: String.t(), opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.File.Link.t()} | {:error, Splode.Error.t()}

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
  @callback update_promotion_code(MishkaPay.Coupon.PromotionCode.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Coupon.PromotionCode.t()} | {:error, Splode.Error.t()}

  @doc "With `:usage`. Makes a meter that counts usage reported under its event name."
  @callback create_meter(MishkaPay.Meter.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Meter.t()} | {:error, Splode.Error.t()}

  @doc "With `:usage`. One page of meters; only those of `:status` (`:active`, `:inactive`) when given."
  @callback list_meters(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:usage`. Turns a meter off: it takes no more usage and no new price."
  @callback deactivate_meter(meter_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Meter.t()} | {:error, Splode.Error.t()}

  @doc "With `:usage`. Turns a meter that was off on again."
  @callback reactivate_meter(meter_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Meter.t()} | {:error, Splode.Error.t()}

  @doc "With `:usage`. Reads one meter again."
  @callback fetch_meter(meter_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Meter.t()} | {:error, Splode.Error.t()}

  @doc "With `:usage`. Renames the meter whose `:id` it carries; how it counts never changes."
  @callback update_meter(MishkaPay.Meter.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Meter.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:usage`. Takes back one usage report by its id (`:usage_id`) under `:event_name`, once
  for each report, and answers it with its `:status`.
  """
  @callback cancel_usage(MishkaPay.Usage.Cancellation.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Usage.Cancellation.t()} | {:error, Splode.Error.t()}

  @doc "With `:usage`. Reports one use by a customer, once for each reference."
  @callback report_usage(MishkaPay.Usage.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Usage.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:usage`. What a meter counted for `:customer_id` from `:from` to `:to` (both
  `DateTime`, `:to` after `:from`).
  """
  @callback usage_summary(meter_id :: String.t(), opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Usage.Summary.t()} | {:error, Splode.Error.t()}

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
  With `:balance`. One page of the balance's movements, newest first, each naming its
  `:payment_id` when it is about one; only those a `:payout_id` paid out, of `:type`, or made by
  `:source_id` (a charge, a refund), when given. `:payment_id` answers the movements of one
  payment (its charge's and its refunds') on one page, and takes no other filter.
  """
  @callback list_balance_transactions(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:customer_balance`. Changes a customer's balance: below zero gives credit."
  @callback adjust_customer_balance(
              MishkaPay.Customer.BalanceTransaction.t(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.Customer.BalanceTransaction.t()} | {:error, Splode.Error.t()}

  @doc "With `:customer_balance`. One page of the changes to `:customer_id`'s balance, newest first."
  @callback list_customer_balance(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:connect`. Makes a connected account for a seller; its `:reference` makes the
  idempotency key.
  """
  @callback create_connected_account(MishkaPay.ConnectedAccount.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.ConnectedAccount.t()} | {:error, Splode.Error.t()}

  @doc "With `:connect`. Reads one connected account; `opts` may name the `:api` to read it with."
  @callback fetch_connected_account(
              account_id :: String.t(),
              opts :: keyword(),
              MishkaPay.Credentials.t()
            ) ::
              {:ok, MishkaPay.ConnectedAccount.t()} | {:error, Splode.Error.t()}

  @doc "With `:connect`. Changes the details of connected account `:id` that are given."
  @callback update_connected_account(MishkaPay.ConnectedAccount.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.ConnectedAccount.t()} | {:error, Splode.Error.t()}

  @doc "With `:connect`. One page of the platform's connected accounts, newest first."
  @callback list_connected_accounts(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:connect`. Closes a connected account for good: it takes no more payments or payouts.
  `opts` may name the `:api`, and a `:reason` where the provider takes one.
  """
  @callback close_connected_account(
              account_id :: String.t(),
              opts :: keyword(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.ConnectedAccount.t()} | {:error, Splode.Error.t()}

  @doc "With `:connect`. Makes a one-time onboarding or update link for a connected account."
  @callback account_link(MishkaPay.ConnectedAccount.Link.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.ConnectedAccount.Link.t()} | {:error, Splode.Error.t()}

  @doc "With `:connect`. Makes a one-time link into a connected account's own dashboard."
  @callback login_link(account_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.ConnectedAccount.Link.t()} | {:error, Splode.Error.t()}

  @doc "With `:connect`. Reads one application fee, the platform's cut of a seller's sale."
  @callback fetch_application_fee(fee_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.ApplicationFee.t()} | {:error, Splode.Error.t()}

  @doc "With `:connect`. One page of application fees, newest first; only `:charge_id`'s when given."
  @callback list_application_fees(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:connect`. Gives an application fee back to the seller: all of it, or `:amount`;
  `:reference` makes the idempotency key. Answers the fee after.
  """
  @callback refund_application_fee(
              fee_id :: String.t(),
              opts :: keyword(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.ApplicationFee.t()} | {:error, Splode.Error.t()}

  @doc "With `:transfer`. Sends money to a connected account; its `:reference` makes it once."
  @callback create_transfer(MishkaPay.Transfer.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Transfer.t()} | {:error, Splode.Error.t()}

  @doc "With `:transfer`. Reads one transfer."
  @callback fetch_transfer(transfer_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Transfer.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:transfer`. One page of transfers, newest first; only those to `:destination` or of
  `:transfer_group` when given.
  """
  @callback list_transfers(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:transfer`. Takes a transfer back from the connected account: all of it, or `:amount`;
  `:reference` makes the idempotency key. Answers the transfer after.
  """
  @callback reverse_transfer(
              transfer_id :: String.t(),
              opts :: keyword(),
              MishkaPay.Credentials.t()
            ) :: {:ok, MishkaPay.Transfer.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:payout`. Pays money of the available balance out to the account's bank or card now, from
  a `MishkaPay.Balance.Payout` with `:amount` and `:reference` (its idempotency key), and the
  `:method`, `:destination_id`, `:statement_descriptor`, `:description` and `:metadata` it gives.
  Refuses a method the provider has not before any request.
  """
  @callback create_payout(MishkaPay.Balance.Payout.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Balance.Payout.t()} | {:error, Splode.Error.t()}

  @doc "With `:payout`. Reads one payout of the account the keys act for."
  @callback fetch_payout(payout_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Balance.Payout.t()} | {:error, Splode.Error.t()}

  @doc "With `:payout`. One page of payouts, newest first; only those of `:status` when given."
  @callback list_payouts(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:payout`. Stops a payout that is still pending; its money stays in the balance."
  @callback cancel_payout(payout_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Balance.Payout.t()} | {:error, Splode.Error.t()}

  @doc "With `:payout_schedule`. Reads when the balance of the account the keys act for is paid out."
  @callback fetch_payout_schedule(MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Balance.PayoutSchedule.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:payout_schedule`. Sets the fields the `MishkaPay.Balance.PayoutSchedule` gives, leaving the
  others as they are, and answers the whole schedule after.
  """
  @callback update_payout_schedule(
              MishkaPay.Balance.PayoutSchedule.t(),
              MishkaPay.Credentials.t()
            ) ::
              {:ok, MishkaPay.Balance.PayoutSchedule.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:payout_destination`. One page of the bank accounts and cards the account the keys act for
  is paid out to; only one `:type` (`:bank_account` or `:card`) when given.
  """
  @callback list_payout_destinations(opts :: keyword(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Page.t()} | {:error, Splode.Error.t()}

  @doc "With `:payout_destination`. Reads one bank account or card payouts go to, by its id."
  @callback fetch_payout_destination(destination_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Balance.PayoutDestination.t()} | {:error, Splode.Error.t()}

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
  With `:raw_request`. Sends one call to `:path` of the provider's own API with the tenant's keys
  and answers the provider's decoded answer as it is, or its error as a `MishkaPay.Errors` one.
  An option of `:options` the provider cannot send is refused before any request.
  """
  @callback raw_request(MishkaPay.RawRequest.t(), MishkaPay.Credentials.t()) ::
              {:ok, map()} | {:error, Splode.Error.t()}

  @doc """
  Optional. Whether the provider takes `keys`, with one read call that changes nothing
  (`MishkaPay.Check`).
  """
  @callback check_keys(MishkaPay.Credentials.t()) :: :ok | {:error, Splode.Error.t()}

  @doc """
  Optional, with `:checkout`. The checkout id the provider put in the query of the page the buyer
  came back to (`MishkaPay.return_checkout_id/2`), checked by shape, or an `Errors.Invalid` on
  `:checkout_id` when the query names none. Left out, Mishka Pay answers `Errors.Unsupported`.
  """
  @callback return_checkout_id(params :: map()) ::
              {:ok, String.t()} | {:error, Splode.Error.t()}

  @optional_callbacks offered?: 0,
                      check_keys: 1,
                      return_checkout_id: 1,
                      checkout: 2,
                      fetch_checkout: 2,
                      fetch_payment: 2,
                      expire_checkout: 2,
                      refund: 2,
                      fetch_refund: 2,
                      capture_payment: 3,
                      cancel_payment: 2,
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
                      create_invoice_item: 2,
                      update_invoice_item: 2,
                      delete_invoice_item: 2,
                      list_invoice_items: 2,
                      create_credit_note: 2,
                      preview_credit_note: 2,
                      fetch_credit_note: 2,
                      void_credit_note: 2,
                      list_credit_notes: 2,
                      list_credit_note_lines: 3,
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
                      list_subscriptions: 2,
                      search_subscriptions: 2,
                      create_subscription_schedule: 2,
                      fetch_subscription_schedule: 2,
                      list_subscription_schedules: 2,
                      update_subscription_schedule: 2,
                      release_subscription_schedule: 2,
                      cancel_subscription_schedule: 3,
                      create_customer: 2,
                      fetch_customer: 2,
                      update_customer: 2,
                      list_customers: 2,
                      delete_customer: 2,
                      create_tax_id: 2,
                      list_tax_ids: 2,
                      delete_tax_id: 3,
                      calculate_tax: 2,
                      record_tax: 3,
                      create_payment_intent: 2,
                      fetch_payment_intent: 2,
                      update_payment_intent: 2,
                      confirm_payment_intent: 3,
                      cancel_payment_intent: 2,
                      create_setup_intent: 2,
                      fetch_setup_intent: 2,
                      confirm_setup_intent: 3,
                      cancel_setup_intent: 2,
                      create_tax_rate: 2,
                      fetch_tax_rate: 2,
                      update_tax_rate: 2,
                      list_tax_rates: 2,
                      create_tax_registration: 2,
                      list_tax_registrations: 2,
                      expire_tax_registration: 3,
                      fetch_tax_settings: 1,
                      update_tax_settings: 2,
                      create_shipping_rate: 2,
                      list_shipping_rates: 2,
                      portal_session: 2,
                      create_portal_configuration: 2,
                      update_portal_configuration: 2,
                      fetch_portal_configuration: 2,
                      list_portal_configurations: 2,
                      list_payment_methods: 2,
                      fetch_payment_method: 2,
                      detach_payment_method: 2,
                      set_default_payment_method: 3,
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
                      fetch_fraud_warning: 2,
                      list_fraud_warnings: 2,
                      fetch_fraud_review: 2,
                      list_fraud_reviews: 2,
                      approve_fraud_review: 2,
                      upload_file: 2,
                      fetch_file: 2,
                      file_link: 3,
                      create_payment_link: 2,
                      fetch_payment_link: 2,
                      list_payment_links: 2,
                      update_payment_link: 2,
                      create_meter: 2,
                      list_meters: 2,
                      deactivate_meter: 2,
                      reactivate_meter: 2,
                      fetch_meter: 2,
                      update_meter: 2,
                      cancel_usage: 2,
                      report_usage: 2,
                      usage_summary: 3,
                      create_feature: 2,
                      attach_feature: 3,
                      list_entitlements: 2,
                      fetch_balance: 1,
                      list_balance_transactions: 2,
                      adjust_customer_balance: 2,
                      list_customer_balance: 2,
                      create_connected_account: 2,
                      fetch_connected_account: 3,
                      update_connected_account: 2,
                      list_connected_accounts: 2,
                      close_connected_account: 3,
                      account_link: 2,
                      login_link: 2,
                      fetch_application_fee: 2,
                      list_application_fees: 2,
                      refund_application_fee: 3,
                      create_transfer: 2,
                      fetch_transfer: 2,
                      list_transfers: 2,
                      reverse_transfer: 3,
                      create_payout: 2,
                      fetch_payout: 2,
                      list_payouts: 2,
                      cancel_payout: 2,
                      fetch_payout_schedule: 1,
                      update_payout_schedule: 2,
                      list_payout_destinations: 2,
                      fetch_payout_destination: 2,
                      raw_request: 2,
                      verify_webhook: 3

  @operations %{
    checkout: [checkout: 2, fetch_checkout: 2, fetch_payment: 2],
    expire: [expire_checkout: 2],
    intent: [
      create_payment_intent: 2,
      fetch_payment_intent: 2,
      update_payment_intent: 2,
      confirm_payment_intent: 3,
      cancel_payment_intent: 2,
      create_setup_intent: 2,
      fetch_setup_intent: 2,
      confirm_setup_intent: 3,
      cancel_setup_intent: 2
    ],
    payment_list: [list_payments: 2],
    refund: [refund: 2],
    capture: [capture_payment: 3, cancel_payment: 2],
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
    subscription_list: [list_subscriptions: 2, search_subscriptions: 2],
    subscription_schedule: [
      create_subscription_schedule: 2,
      fetch_subscription_schedule: 2,
      list_subscription_schedules: 2,
      update_subscription_schedule: 2,
      release_subscription_schedule: 2,
      cancel_subscription_schedule: 3
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
    invoice_item: [
      create_invoice_item: 2,
      update_invoice_item: 2,
      delete_invoice_item: 2,
      list_invoice_items: 2
    ],
    credit_note: [
      create_credit_note: 2,
      preview_credit_note: 2,
      fetch_credit_note: 2,
      void_credit_note: 2,
      list_credit_notes: 2,
      list_credit_note_lines: 3
    ],
    customer: [
      create_customer: 2,
      fetch_customer: 2,
      update_customer: 2,
      list_customers: 2,
      search_customers: 2,
      delete_customer: 2
    ],
    tax_id: [create_tax_id: 2, list_tax_ids: 2, delete_tax_id: 3],
    tax: [calculate_tax: 2, record_tax: 3],
    tax_rate: [create_tax_rate: 2, fetch_tax_rate: 2, update_tax_rate: 2, list_tax_rates: 2],
    tax_setup: [
      create_tax_registration: 2,
      list_tax_registrations: 2,
      expire_tax_registration: 3,
      fetch_tax_settings: 1,
      update_tax_settings: 2
    ],
    shipping: [create_shipping_rate: 2, list_shipping_rates: 2],
    portal: [
      portal_session: 2,
      create_portal_configuration: 2,
      update_portal_configuration: 2,
      fetch_portal_configuration: 2,
      list_portal_configurations: 2
    ],
    payment_method: [
      list_payment_methods: 2,
      fetch_payment_method: 2,
      detach_payment_method: 2,
      set_default_payment_method: 3
    ],
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
    fraud: [
      fetch_fraud_warning: 2,
      list_fraud_warnings: 2,
      fetch_fraud_review: 2,
      list_fraud_reviews: 2,
      approve_fraud_review: 2
    ],
    file: [upload_file: 2, fetch_file: 2, file_link: 3],
    payment_link: [
      create_payment_link: 2,
      fetch_payment_link: 2,
      list_payment_links: 2,
      update_payment_link: 2
    ],
    usage: [
      create_meter: 2,
      fetch_meter: 2,
      update_meter: 2,
      list_meters: 2,
      deactivate_meter: 2,
      reactivate_meter: 2,
      report_usage: 2,
      cancel_usage: 2,
      usage_summary: 3
    ],
    entitlement: [create_feature: 2, attach_feature: 3, list_entitlements: 2],
    balance: [fetch_balance: 1, list_balance_transactions: 2],
    customer_balance: [adjust_customer_balance: 2, list_customer_balance: 2],
    connect: [
      create_connected_account: 2,
      fetch_connected_account: 3,
      update_connected_account: 2,
      list_connected_accounts: 2,
      close_connected_account: 3,
      account_link: 2,
      login_link: 2,
      fetch_application_fee: 2,
      list_application_fees: 2,
      refund_application_fee: 3
    ],
    transfer: [create_transfer: 2, fetch_transfer: 2, list_transfers: 2, reverse_transfer: 3],
    payout: [create_payout: 2, fetch_payout: 2, list_payouts: 2, cancel_payout: 2],
    payout_schedule: [fetch_payout_schedule: 1, update_payout_schedule: 2],
    payout_destination: [list_payout_destinations: 2, fetch_payout_destination: 2],
    webhook: [verify_webhook: 3],
    raw_request: [raw_request: 2]
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

  @doc """
  The name a person reads for provider `id`: its `label/0` when it is installed (`"Stripe"`,
  `"PayPal"`), else the id with a capital.
  """
  @spec label_of(String.t() | nil) :: String.t()
  def label_of(id) when is_binary(id) do
    case fetch(id) do
      {:ok, provider} -> provider.label()
      {:error, _unknown} -> String.capitalize(id)
    end
  end

  def label_of(_none), do: "The provider"

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

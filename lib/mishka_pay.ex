# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay do
  @moduledoc """
  The calls a project makes to take money: open a checkout, read a payment, refund one; for a
  subscription (started by a checkout in `mode: :subscription`) read it, cancel it, take a cancel
  back and list its invoices; keep customers (create, read, update, list, delete) and open their billing
  portal; save a customer's card with a checkout in `mode: :setup` and keep their saved payment
  methods; keep coupons and promotion codes; keep a catalog of products and prices; make payment
  links that sell them; end an open
  checkout; list payments, subscriptions, invoices, customers, coupons, codes, products and prices
  page by page (`MishkaPay.Page`).

      {:ok, checkout} =
        MishkaPay.checkout(%{
          provider: "stripe",
          tenant: site_id,
          items: [%{name: "Ebook", amount: %{amount: "19.99", currency: "USD"}}],
          success_url: "https://shop.test/thanks",
          cancel_url: "https://shop.test/cart",
          reference: order.id
        })

      redirect(conn, external: checkout.url)

  Each call names a provider by its id, finds it among the installed providers
  (`MishkaPay.Provider.fetch/1`), checks it has the capability, takes the tenant's keys from
  `MishkaPay.Credentials` and hands the provider a checked guarded_struct. The answer is a
  guarded_struct or a `MishkaPay.Errors` error, the same for every provider. This module never
  names a provider: a project chooses which run by supervising their plugins.

  ## Before a checkout

  `checkout/1` fires `mishka_pay:checkout:before` (`MishkaPay.Events.checkout_before/0`) with the
  checked checkout. A host plugin may change it (add metadata, set the customer) or refuse it with
  a reason, which comes back as a `MishkaPay.Errors.Refused` error. A gate that does not answer
  refuses too, with the reason why: it cannot run, raises, exits or throws, gives no answer within
  `config :mishka_pay, checkout_gate_timeout: ms` (5 seconds), or answers something that is not
  a checkout (`:invalid_answer`). A sale never goes ahead on a gate that did not say yes. The gate
  runs like the keys plugins, in a task that cannot take the caller down.

  ## Telemetry

  Each call is a span, `[:mishka_pay, operation, :start | :stop]`, with `:provider` and `:tenant`
  in its metadata and, on `:stop`, the `:outcome`: `:ok` or the error's class (`:invalid`,
  `:provider`, `:unknown`). Never a key or a buyer's details. The operations:

    * checkouts and payments: `:checkout`, `:checkout_read`, `:checkout_expire`, `:payment`,
      `:payment_list`, `:payment_capture`, `:payment_cancel`, `:refund`, `:refund_read`,
      `:refund_list`;
    * the site's own card form: `:payment_intent_create`, `:payment_intent`,
      `:payment_intent_update`, `:payment_intent_confirm`, `:payment_intent_cancel`,
      `:setup_intent_create`, `:setup_intent`, `:setup_intent_confirm`, `:setup_intent_cancel`;
    * subscriptions: `:subscription`, `:subscription_cancel`, `:subscription_resume`,
      `:subscription_change`, `:subscription_preview`, `:subscription_pause`,
      `:subscription_unpause`, `:subscription_list`, `:subscription_search`, `:invoices`,
      `:invoice`, `:invoice_upcoming`, and their schedules: `:subscription_schedule_create`,
      `:subscription_schedule`, `:subscription_schedule_list`, `:subscription_schedule_update`,
      `:subscription_schedule_release`, `:subscription_schedule_cancel`;
    * one-off bills: `:invoice_create`, `:invoice_finalize`, `:invoice_send`, `:invoice_pay`,
      `:invoice_void`, `:invoice_uncollectible`, `:invoice_delete`, and charges kept for a bill:
      `:invoice_item_create`, `:invoice_item_update`, `:invoice_item_delete`,
      `:invoice_item_list`, and credit notes: `:credit_note_create`, `:credit_note_preview`,
      `:credit_note`, `:credit_note_void`, `:credit_note_list`, `:credit_note_line_list`;
    * customers: `:customer_create`, `:customer_update`, `:customer`, `:customer_list`,
      `:customer_search`, `:customer_delete`, `:portal`, the portal's setups:
      `:portal_configuration_create`, `:portal_configuration_update`, `:portal_configuration`,
      `:portal_configuration_list`, and their tax ids: `:tax_id_create`, `:tax_id_list`,
      `:tax_id_delete`;
    * saved payment methods: `:payment_method_list`, `:payment_method`,
      `:payment_method_detach`, `:payment_method_default`;
    * tax outside a checkout: `:tax_calculate`, `:tax_record`; tax rates set by hand:
      `:tax_rate_create`, `:tax_rate`, `:tax_rate_update`, `:tax_rate_list`; the tax setup:
      `:tax_registration_create`, `:tax_registration_list`, `:tax_registration_expire`,
      `:tax_settings`, `:tax_settings_update`;
    * shipping: `:shipping_rate_create`, `:shipping_rate_list`;
    * discounts: `:coupon_create`, `:coupon`, `:coupon_list`, `:coupon_delete`,
      `:promotion_code_create`, `:promotion_code`, `:promotion_code_list`,
      `:promotion_code_update`;
    * the catalog: `:product_create`, `:product`, `:product_update`, `:product_list`,
      `:price_create`, `:price`, `:price_update`, `:price_list`;
    * payment links: `:payment_link_create`, `:payment_link`, `:payment_link_update`,
      `:payment_link_list`;
    * disputes: `:dispute`, `:dispute_list`, `:dispute_update`, `:dispute_accept`;
    * fraud: `:fraud_warning`, `:fraud_warning_list`, `:fraud_review`, `:fraud_review_list`,
      `:fraud_review_approve`;
    * files: `:file_upload`, `:file`, `:file_link`;
    * usage billing: `:meter_create`, `:meter`, `:meter_update`, `:meter_list`,
      `:meter_deactivate`, `:meter_reactivate`, `:usage_report`, `:usage_cancel`,
      `:usage_summary`;
    * entitlements: `:feature_create`, `:feature_attach`, `:entitlement_list`;
    * money views: `:balance`, `:balance_transaction_list`, `:customer_balance_adjust`,
      `:customer_balance_list`;
    * a platform's sellers: `:connected_account_create`, `:connected_account`,
      `:connected_account_update`, `:connected_account_list`, `:connected_account_close`,
      `:account_link`, `:login_link`, `:application_fee`, `:application_fee_list`,
      `:application_fee_refund`; money between accounts: `:transfer_create`, `:transfer`,
      `:transfer_list`, `:transfer_reverse`, `:payout_create`, `:payout`, `:payout_list`,
      `:payout_cancel`, `:payout_schedule`, `:payout_schedule_update`, `:payout_destination`,
      `:payout_destination_list`;
    * events: `:event_list`;
    * a call to the provider's own API: `:raw_request`.
  """

  alias MishkaPay.{
    Checkout,
    Coupon,
    Credentials,
    Customer,
    Errors,
    Events,
    Messages,
    Page,
    PaymentLink,
    PortalSession,
    Price,
    Product,
    Provider,
    ProviderKit,
    Refund
  }

  alias MishkaPay.Helpers.Plugins

  @doc "Opens a checkout from `attrs` (see `MishkaPay.Checkout`) and answers it with the provider's page."
  @spec checkout(map()) :: {:ok, Checkout.t()} | {:error, Splode.Error.t()}
  def checkout(attrs) when is_map(attrs) do
    span(:checkout, attrs, fn ->
      with {:ok, checkout} <- Errors.from_builder(Checkout.builder(attrs)),
           :ok <- Checkout.pages(checkout),
           {:ok, provider} <- Provider.capable(checkout.provider, :checkout),
           :ok <- mode_capable(checkout),
           {:ok, checkout} <- before_checkout(checkout),
           {:ok, keys} <- Credentials.fetch(checkout.provider, checkout.tenant) do
        provider.checkout(checkout, keys)
      end
    end)
  end

  @doc """
  Reads checkout `checkout_id` again from `provider`, with `tenant`'s keys: its `:status` and the
  `:payment_id` it made. A success page calls it with the id the provider put in its URL, to show
  the sale at once without waiting for the webhook.
  """
  @spec fetch_checkout(String.t(), String.t(), term()) ::
          {:ok, Checkout.t()} | {:error, Splode.Error.t()}
  def fetch_checkout(provider, checkout_id, tenant \\ nil)
      when is_binary(provider) and is_binary(checkout_id) do
    span(:checkout_read, %{provider: provider, tenant: tenant}, fn ->
      with {:ok, module} <- Provider.capable(provider, :checkout),
           {:ok, keys} <- Credentials.fetch(provider, tenant) do
        module.fetch_checkout(checkout_id, keys)
      end
    end)
  end

  @doc "Reads payment `payment_id` again from `provider`, with `tenant`'s keys."
  @spec fetch_payment(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Payment.t()} | {:error, Splode.Error.t()}
  def fetch_payment(provider, payment_id, tenant \\ nil)
      when is_binary(provider) and is_binary(payment_id) do
    span(:payment, %{provider: provider, tenant: tenant}, fn ->
      with {:ok, module} <- Provider.capable(provider, :checkout),
           {:ok, keys} <- Credentials.fetch(provider, tenant) do
        module.fetch_payment(payment_id, keys)
      end
    end)
  end

  @doc """
  Takes the money held on `:authorized` payment `payment_id` (a checkout with `capture: :manual`):
  all of it, or `amount:` (a `Money`, or a map of `:amount` and `:currency`, in the payment's
  currency) and the rest is let go. Answers the payment, `:paid`, with `:amount_captured`.
  """
  @spec capture_payment(String.t(), String.t(), term(), keyword()) ::
          {:ok, MishkaPay.Payment.t()} | {:error, Splode.Error.t()}
  def capture_payment(provider, payment_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(payment_id) do
    capable(:capture, :payment_capture, provider, tenant, fn module, keys ->
      with {:ok, amount} <- part_amount(opts[:amount]),
           do: module.capture_payment(payment_id, [amount: amount], keys)
    end)
  end

  @doc """
  Lets the money held on `:authorized` payment `payment_id` go back to the buyer; the payment ends
  `:canceled`.
  """
  @spec cancel_payment(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Payment.t()} | {:error, Splode.Error.t()}
  def cancel_payment(provider, payment_id, tenant \\ nil)
      when is_binary(provider) and is_binary(payment_id) do
    capable(:capture, :payment_cancel, provider, tenant, & &1.cancel_payment(payment_id, &2))
  end

  @doc """
  Makes a payment intent from `attrs` (see `MishkaPay.PaymentIntent`): an `:amount`, and the
  `:customer_id`, `:payment_method_id`, `:capture`, `:setup_future_usage` and `:reference` it
  needs. Hand its `:client_secret` to that buyer's page only, where the provider's card form
  (Stripe Elements) confirms it; then read it again before giving access.
  """
  @spec create_payment_intent(map()) ::
          {:ok, MishkaPay.PaymentIntent.t()} | {:error, Splode.Error.t()}
  def create_payment_intent(attrs) when is_map(attrs) do
    made(
      :payment_intent_create,
      :intent,
      attrs,
      MishkaPay.PaymentIntent,
      [:provider, :amount],
      :create_payment_intent
    )
  end

  @doc "Reads payment intent `payment_intent_id` from `provider`, with its status."
  @spec fetch_payment_intent(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.PaymentIntent.t()} | {:error, Splode.Error.t()}
  def fetch_payment_intent(provider, payment_intent_id, tenant \\ nil)
      when is_binary(provider) and is_binary(payment_intent_id) do
    capable(
      :intent,
      :payment_intent,
      provider,
      tenant,
      & &1.fetch_payment_intent(payment_intent_id, &2)
    )
  end

  @doc """
  Changes payment intent `attrs.id` before it is paid: only the fields given (`:amount`,
  `:customer_id`, `:payment_method_id`, `:capture`, `:setup_future_usage`, `:description`,
  `:metadata`).
  """
  @spec update_payment_intent(map()) ::
          {:ok, MishkaPay.PaymentIntent.t()} | {:error, Splode.Error.t()}
  def update_payment_intent(attrs) when is_map(attrs) do
    made(
      :payment_intent_update,
      :intent,
      attrs,
      MishkaPay.PaymentIntent,
      [:provider, :id],
      :update_payment_intent
    )
  end

  @doc """
  Confirms payment intent `payment_intent_id` on the server: `payment_method_id:` a saved payment
  method, and `return_url:` where a payment method's own page (3D Secure, a bank) sends the
  buyer back (`https`, or `http` on `localhost`). A page with the card form confirms in the
  browser instead.
  """
  @spec confirm_payment_intent(String.t(), String.t(), term(), keyword()) ::
          {:ok, MishkaPay.PaymentIntent.t()} | {:error, Splode.Error.t()}
  def confirm_payment_intent(provider, payment_intent_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(payment_intent_id) do
    capable(:intent, :payment_intent_confirm, provider, tenant, fn module, keys ->
      with {:ok, opts} <- confirm_opts(opts),
           do: module.confirm_payment_intent(payment_intent_id, opts, keys)
    end)
  end

  @doc """
  Cancels payment intent `payment_intent_id` before it is paid, or lets the money a held one
  (`:requires_capture`) keeps go back. Answers it `:canceled`.
  """
  @spec cancel_payment_intent(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.PaymentIntent.t()} | {:error, Splode.Error.t()}
  def cancel_payment_intent(provider, payment_intent_id, tenant \\ nil)
      when is_binary(provider) and is_binary(payment_intent_id) do
    capable(
      :intent,
      :payment_intent_cancel,
      provider,
      tenant,
      & &1.cancel_payment_intent(payment_intent_id, &2)
    )
  end

  @doc """
  Makes a setup intent from `attrs` (see `MishkaPay.SetupIntent`): it saves a payment method on
  `:customer_id` with the provider's card form on the site's own page, and charges nothing. Hand
  its `:client_secret` to that buyer's page only.
  """
  @spec create_setup_intent(map()) ::
          {:ok, MishkaPay.SetupIntent.t()} | {:error, Splode.Error.t()}
  def create_setup_intent(attrs) when is_map(attrs) do
    made(
      :setup_intent_create,
      :intent,
      attrs,
      MishkaPay.SetupIntent,
      [:provider],
      :create_setup_intent
    )
  end

  @doc "Reads setup intent `setup_intent_id` from `provider`, with its status."
  @spec fetch_setup_intent(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.SetupIntent.t()} | {:error, Splode.Error.t()}
  def fetch_setup_intent(provider, setup_intent_id, tenant \\ nil)
      when is_binary(provider) and is_binary(setup_intent_id) do
    capable(
      :intent,
      :setup_intent,
      provider,
      tenant,
      & &1.fetch_setup_intent(setup_intent_id, &2)
    )
  end

  @doc """
  Confirms setup intent `setup_intent_id` on the server, with `payment_method_id:` and
  `return_url:` as `confirm_payment_intent/4`.
  """
  @spec confirm_setup_intent(String.t(), String.t(), term(), keyword()) ::
          {:ok, MishkaPay.SetupIntent.t()} | {:error, Splode.Error.t()}
  def confirm_setup_intent(provider, setup_intent_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(setup_intent_id) do
    capable(:intent, :setup_intent_confirm, provider, tenant, fn module, keys ->
      with {:ok, opts} <- confirm_opts(opts),
           do: module.confirm_setup_intent(setup_intent_id, opts, keys)
    end)
  end

  @doc "Cancels setup intent `setup_intent_id`, which has not succeeded. Answers it `:canceled`."
  @spec cancel_setup_intent(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.SetupIntent.t()} | {:error, Splode.Error.t()}
  def cancel_setup_intent(provider, setup_intent_id, tenant \\ nil)
      when is_binary(provider) and is_binary(setup_intent_id) do
    capable(
      :intent,
      :setup_intent_cancel,
      provider,
      tenant,
      & &1.cancel_setup_intent(setup_intent_id, &2)
    )
  end

  # A confirm's return URL follows the rule of a checkout's pages.
  defp confirm_opts(opts) do
    case MishkaPay.Checkout.return_url(:return_url, opts[:return_url]) do
      {:ok, :return_url, _url} -> {:ok, Keyword.take(opts, [:payment_method_id, :return_url])}
      {:error, field, message} -> ProviderKit.invalid(field, message)
    end
  end

  # The part to take or give back: money above zero, or nil for all of it.
  defp part_amount(nil), do: {:ok, nil}

  defp part_amount(amount) do
    case MishkaPay.Money.field(:amount, amount) do
      {:ok, :amount, %Money{} = money} ->
        if Money.positive?(money),
          do: {:ok, money},
          else: ProviderKit.invalid(:amount, Messages.text(:amount_not_positive))

      {:error, field, message} ->
        ProviderKit.invalid(field, message)
    end
  end

  @doc "Refunds a payment from `attrs` (see `MishkaPay.Refund`), in full or in part."
  @spec refund(map()) :: {:ok, Refund.t()} | {:error, Splode.Error.t()}
  def refund(attrs) when is_map(attrs) do
    span(:refund, attrs, fn ->
      with {:ok, refund} <- Errors.from_builder(Refund.builder(attrs)),
           {:ok, provider} <- Provider.capable(refund.provider, :refund),
           {:ok, keys} <- Credentials.fetch(refund.provider, refund.tenant) do
        provider.refund(refund, keys)
      end
    end)
  end

  @doc "Reads refund `refund_id` from `provider` again, with its status."
  @spec fetch_refund(String.t(), String.t(), term()) ::
          {:ok, Refund.t()} | {:error, Splode.Error.t()}
  def fetch_refund(provider, refund_id, tenant \\ nil)
      when is_binary(provider) and is_binary(refund_id) do
    capable(:refund_read, :refund_read, provider, tenant, & &1.fetch_refund(refund_id, &2))
  end

  @doc """
  One page of refunds at `provider`, newest first (`MishkaPay.Page`): `payment_id:` only one
  payment's, plus `limit:` and `after:`.
  """
  @spec list_refunds(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_refunds(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:refund_read, :refund_list, provider, tenant, & &1.list_refunds(limited(opts), &2))
  end

  @doc """
  Makes a customer from `attrs` (see `MishkaPay.Customer`): `:provider`, `:tenant`, and the
  buyer's `:email`, `:name`, `:phone`, `:address`, `:reference`, `:metadata`; `:api` picks the
  provider's API (else the tenant's `:customer_api`, `:v2` by default: at Stripe an account with
  the customer configuration, `acct_...`). Keep its `:id` on the host's user to sell to them
  again.
  """
  @spec create_customer(map()) :: {:ok, Customer.t()} | {:error, Splode.Error.t()}
  def create_customer(attrs) when is_map(attrs) do
    span(:customer_create, attrs, fn ->
      with {:ok, customer} <- built(Customer.builder(attrs), [:provider]),
           {:ok, module} <- Provider.capable(customer.provider, :customer),
           {:ok, keys} <- Credentials.fetch(customer.provider, customer.tenant) do
        module.create_customer(customer, keys)
      end
    end)
  end

  @doc "Changes customer `attrs.id` at `attrs.provider`: only the fields given are sent."
  @spec update_customer(map()) :: {:ok, Customer.t()} | {:error, Splode.Error.t()}
  def update_customer(attrs) when is_map(attrs) do
    span(:customer_update, attrs, fn ->
      with {:ok, customer} <- built(Customer.builder(attrs), [:provider, :id]),
           {:ok, module} <- Provider.capable(customer.provider, :customer),
           {:ok, keys} <- Credentials.fetch(customer.provider, customer.tenant) do
        module.update_customer(customer, keys)
      end
    end)
  end

  @doc """
  Reads customer `customer_id` again from `provider`, with `tenant`'s keys, on the API its id
  belongs to (at Stripe `acct_...` on Accounts v2, `cus_...` on Customers).
  """
  @spec fetch_customer(String.t(), String.t(), term()) ::
          {:ok, Customer.t()} | {:error, Splode.Error.t()}
  def fetch_customer(provider, customer_id, tenant \\ nil)
      when is_binary(provider) and is_binary(customer_id) do
    capable(:customer, :customer, provider, tenant, & &1.fetch_customer(customer_id, &2))
  end

  @doc """
  Deletes customer `customer_id` at `provider` for good, such as for a person's erase request.
  The provider drops their saved cards and ends their running subscriptions at once (Stripe
  does); past payments and invoices stay. The customer reads back as deleted after
  (`MishkaPay.Errors.Rejected` with code `"customer_deleted"`).
  """
  @spec delete_customer(String.t(), String.t(), term()) :: :ok | {:error, Splode.Error.t()}
  def delete_customer(provider, customer_id, tenant \\ nil)
      when is_binary(provider) and is_binary(customer_id) do
    capable(:customer, :customer_delete, provider, tenant, & &1.delete_customer(customer_id, &2))
  end

  @doc """
  One page of customers at `provider`, newest first (`MishkaPay.Page`): `email:` only those with
  that email, plus the list options `limit:` and `after:`. `api:` lists on `:v2` or `:v1` instead
  of the tenant's `:customer_api`; Stripe's Accounts v2 lists have no email filter (find by email
  with `search_customers/3`) and hold at most 20 a page.
  """
  @spec list_customers(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_customers(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:customer, :customer_list, provider, tenant, & &1.list_customers(limited(opts), &2))
  end

  @doc """
  Adds a business buyer's tax id to customer `customer_id` from `attrs` (see `MishkaPay.Customer.TaxId`):
  its `:type`, such as `"eu_vat"`, and its `:value`. The provider prints it on the customer's
  invoices, and checks it against a government register for the kinds it can
  (`:verification`).

      MishkaPay.create_tax_id("stripe", "cus_123", %{type: "eu_vat", value: "DE123456789"}, site_id)
  """
  @spec create_tax_id(String.t(), String.t(), map(), term()) ::
          {:ok, Customer.TaxId.t()} | {:error, Splode.Error.t()}
  def create_tax_id(provider, customer_id, attrs, tenant \\ nil)
      when is_binary(provider) and is_binary(customer_id) and is_map(attrs) do
    attrs = %{
      provider: provider,
      tenant: tenant,
      customer_id: customer_id,
      type: field(attrs, :type),
      value: field(attrs, :value)
    }

    made(:tax_id_create, :tax_id, attrs, Customer.TaxId, [:type, :value], :create_tax_id)
  end

  @doc """
  One page of customer `customer_id`'s tax ids at `provider` (`MishkaPay.Page` of
  `MishkaPay.Customer.TaxId`), with `limit:` and `after:`.
  """
  @spec list_tax_ids(String.t(), String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_tax_ids(provider, customer_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(customer_id) do
    opts = opts |> Keyword.put(:customer_id, customer_id) |> limited()
    capable(:tax_id, :tax_id_list, provider, tenant, & &1.list_tax_ids(opts, &2))
  end

  @doc "Removes tax id `tax_id_id` from customer `customer_id`; past invoices keep it."
  @spec delete_tax_id(String.t(), String.t(), String.t(), term()) ::
          :ok | {:error, Splode.Error.t()}
  def delete_tax_id(provider, customer_id, tax_id_id, tenant \\ nil)
      when is_binary(provider) and is_binary(customer_id) and is_binary(tax_id_id) do
    capable(
      :tax_id,
      :tax_id_delete,
      provider,
      tenant,
      & &1.delete_tax_id(customer_id, tax_id_id, &2)
    )
  end

  @doc """
  Makes a shipping rate from `attrs` (see `MishkaPay.ShippingRate`): its `:name`, its `:amount`
  for the whole order, and a delivery estimate. A checkout offers it by its `:id` in
  `:shipping_rates`.
  """
  @spec create_shipping_rate(map()) ::
          {:ok, MishkaPay.ShippingRate.t()} | {:error, Splode.Error.t()}
  def create_shipping_rate(attrs) when is_map(attrs) do
    made(
      :shipping_rate_create,
      :shipping,
      attrs,
      MishkaPay.ShippingRate,
      [:provider, :name, :amount],
      :create_shipping_rate
    )
  end

  @doc """
  One page of shipping rates at `provider`, newest first (`MishkaPay.Page`): `active:` only those
  that can (or cannot) be offered, plus `limit:` and `after:`.
  """
  @spec list_shipping_rates(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_shipping_rates(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(
      :shipping,
      :shipping_rate_list,
      provider,
      tenant,
      & &1.list_shipping_rates(limited(opts), &2)
    )
  end

  @doc """
  Counts the tax on a sale made outside the provider's checkout, from `attrs` (see
  `MishkaPay.TaxCalculation`): its lines, the buyer's address or customer, and shipping. Show the
  answer's `:tax_amount_exclusive` and charge its `:amount_total`; once paid, report the sale
  with `record_tax/4`.

      MishkaPay.calculate_tax(%{
        provider: "stripe",
        tenant: site_id,
        items: [%{reference: "sku-1", amount: %{amount: "30.00", currency: "EUR"}, quantity: 2}],
        address: %{country: "NL", postal_code: "1012"}
      })
  """
  @spec calculate_tax(map()) :: {:ok, MishkaPay.TaxCalculation.t()} | {:error, Splode.Error.t()}
  def calculate_tax(attrs) when is_map(attrs) do
    made(:tax_calculate, :tax, attrs, MishkaPay.TaxCalculation, [:provider], :calculate_tax)
  end

  @doc """
  Records the sale counted by tax calculation `calculation_id` under the caller's `reference`
  (an order id, one sale per reference), so the provider counts its tax in the site's tax
  reports. A calculation can be recorded until its `:expires_at`.
  """
  @spec record_tax(String.t(), String.t(), String.t(), term()) ::
          {:ok, MishkaPay.TaxCalculation.Transaction.t()} | {:error, Splode.Error.t()}
  def record_tax(provider, calculation_id, reference, tenant \\ nil)
      when is_binary(provider) and is_binary(calculation_id) and is_binary(reference) do
    case String.trim(reference) do
      "" ->
        MishkaPay.ProviderKit.invalid(
          :reference,
          Messages.text(:customer_needs, field: :reference)
        )

      reference ->
        capable(
          :tax,
          :tax_record,
          provider,
          tenant,
          & &1.record_tax(calculation_id, reference, &2)
        )
    end
  end

  @doc """
  Makes a tax rate from `attrs` (see `MishkaPay.TaxRate`): a `:display_name`, a `:percentage` and
  whether it is `:inclusive`, and where it applies. Put its `:id` in a line's or a bill's
  `:tax_rate_ids`. Its `:reference` makes it once.
  """
  @spec create_tax_rate(map()) :: {:ok, MishkaPay.TaxRate.t()} | {:error, Splode.Error.t()}
  def create_tax_rate(attrs) when is_map(attrs) do
    needed = [:provider, :display_name, :percentage, :inclusive]
    made(:tax_rate_create, :tax_rate, attrs, MishkaPay.TaxRate, needed, :create_tax_rate)
  end

  @doc "Reads tax rate `tax_rate_id` from `provider`, with `tenant`'s keys."
  @spec fetch_tax_rate(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.TaxRate.t()} | {:error, Splode.Error.t()}
  def fetch_tax_rate(provider, tax_rate_id, tenant \\ nil)
      when is_binary(provider) and is_binary(tax_rate_id) do
    capable(:tax_rate, :tax_rate, provider, tenant, & &1.fetch_tax_rate(tax_rate_id, &2))
  end

  @doc """
  Changes tax rate `attrs.id` at `attrs.provider`: only the fields given (`:active`,
  `:display_name`, `:description`, the place, `:tax_type`, `:metadata`). `active: false` archives
  it. Its `:percentage` and `:inclusive` never change: make a new rate instead.
  """
  @spec update_tax_rate(map()) :: {:ok, MishkaPay.TaxRate.t()} | {:error, Splode.Error.t()}
  def update_tax_rate(%{} = attrs) do
    in_place(attrs, [:percentage, :inclusive], :tax_rate_fixed, fn ->
      made(:tax_rate_update, :tax_rate, attrs, MishkaPay.TaxRate, [:provider], :update_tax_rate)
    end)
  end

  @doc """
  One page of `provider`'s tax rates, newest first (`MishkaPay.Page` of `MishkaPay.TaxRate`):
  `active: true` or `false`, `inclusive: true` or `false`, plus `limit:` and `after:`.
  """
  @spec list_tax_rates(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_tax_rates(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:tax_rate, :tax_rate_list, provider, tenant, & &1.list_tax_rates(limited(opts), &2))
  end

  @doc """
  Registers the seller to collect tax in a country, from `attrs` (see `MishkaPay.TaxSettings.Registration`):
  its `:country` and `:type`, a `:state` where the kind needs one, the `:place_of_supply_scheme`
  of a standard registration, and when it starts and ends.
  The provider's tax counting then charges tax there.
  """
  @spec create_tax_registration(map()) ::
          {:ok, MishkaPay.TaxSettings.Registration.t()} | {:error, Splode.Error.t()}
  def create_tax_registration(attrs) when is_map(attrs) do
    made(
      :tax_registration_create,
      :tax_setup,
      attrs,
      MishkaPay.TaxSettings.Registration,
      [:provider, :country, :type],
      :create_tax_registration
    )
  end

  @doc """
  One page of the seller's tax registrations (`MishkaPay.Page` of `MishkaPay.TaxSettings.Registration`):
  `status:` `:active` (the provider's default), `:scheduled`, `:expired` or `:all`, plus `limit:`
  and `after:`.
  """
  @spec list_tax_registrations(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_tax_registrations(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(
      :tax_setup,
      :tax_registration_list,
      provider,
      tenant,
      & &1.list_tax_registrations(limited(opts), &2)
    )
  end

  @doc """
  Ends tax registration `registration_id`, now or `at:` a later `DateTime`: the provider stops
  charging tax there. A registration is never deleted. Answers it after.
  """
  @spec expire_tax_registration(String.t(), String.t(), term(), keyword()) ::
          {:ok, MishkaPay.TaxSettings.Registration.t()} | {:error, Splode.Error.t()}
  def expire_tax_registration(provider, registration_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(registration_id) do
    capable(
      :tax_setup,
      :tax_registration_expire,
      provider,
      tenant,
      & &1.expire_tax_registration(registration_id, opts[:at], &2)
    )
  end

  @doc "Reads `tenant`'s tax settings at `provider` (`MishkaPay.TaxSettings`)."
  @spec fetch_tax_settings(String.t(), term()) ::
          {:ok, MishkaPay.TaxSettings.t()} | {:error, Splode.Error.t()}
  def fetch_tax_settings(provider, tenant \\ nil) when is_binary(provider) do
    capable(:tax_setup, :tax_settings, provider, tenant, & &1.fetch_tax_settings(&2))
  end

  @doc """
  Changes the tax settings of `attrs.tenant` at `attrs.provider` (see `MishkaPay.TaxSettings`):
  the `:head_office`, the default `:tax_code` and `:tax_behavior`, only those given. Answers them
  after, with the `:status` they leave.
  """
  @spec update_tax_settings(map()) ::
          {:ok, MishkaPay.TaxSettings.t()} | {:error, Splode.Error.t()}
  def update_tax_settings(attrs) when is_map(attrs) do
    made(
      :tax_settings_update,
      :tax_setup,
      attrs,
      MishkaPay.TaxSettings,
      [:provider],
      :update_tax_settings
    )
  end

  @doc """
  Opens the provider's billing page for one customer (see `MishkaPay.PortalSession`): `:provider`,
  `:tenant`, `:customer_id`, `:return_url`, and `:configuration`, the `:id` of a
  `MishkaPay.PortalSession.Configuration` (the provider's default one when left out). Redirect the buyer
  to the answer's `:url`.
  """
  @spec portal_session(map()) :: {:ok, PortalSession.t()} | {:error, Splode.Error.t()}
  def portal_session(attrs) when is_map(attrs) do
    span(:portal, attrs, fn ->
      with {:ok, session} <- Errors.from_builder(PortalSession.builder(attrs)),
           {:ok, module} <- Provider.capable(session.provider, :portal),
           {:ok, keys} <- Credentials.fetch(session.provider, session.tenant) do
        module.portal_session(session, keys)
      end
    end)
  end

  @doc """
  Makes a setup of the customer portal from `attrs` (see `MishkaPay.PortalSession.Configuration`): what
  buyers may do there (cancel, switch plan and to which prices, change their card or details, see
  their bills) and the page's header. A portal session uses it by its `:id` (`:configuration`).

      MishkaPay.create_portal_configuration(%{provider: "stripe", tenant: site_id,
        name: "Teams", subscription_cancel: :at_period_end, invoice_history: true,
        payment_method_update: true, subscription_update: [:price, :quantity],
        plans: [%{product_id: "prod_team", price_ids: ["price_monthly", "price_yearly"]}]})
  """
  @spec create_portal_configuration(map()) ::
          {:ok, MishkaPay.PortalSession.Configuration.t()} | {:error, Splode.Error.t()}
  def create_portal_configuration(attrs) when is_map(attrs) do
    made(
      :portal_configuration_create,
      :portal,
      attrs,
      MishkaPay.PortalSession.Configuration,
      [:provider],
      :create_portal_configuration
    )
  end

  @doc """
  Changes portal setup `attrs.id` at `attrs.provider`: only the fields given. `active: false`
  turns it off; a provider never deletes one.
  """
  @spec update_portal_configuration(map()) ::
          {:ok, MishkaPay.PortalSession.Configuration.t()} | {:error, Splode.Error.t()}
  def update_portal_configuration(attrs) when is_map(attrs) do
    made(
      :portal_configuration_update,
      :portal,
      attrs,
      MishkaPay.PortalSession.Configuration,
      [:provider, :id],
      :update_portal_configuration
    )
  end

  @doc "Reads portal setup `configuration_id` from `provider`, with `tenant`'s keys."
  @spec fetch_portal_configuration(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.PortalSession.Configuration.t()} | {:error, Splode.Error.t()}
  def fetch_portal_configuration(provider, configuration_id, tenant \\ nil)
      when is_binary(provider) and is_binary(configuration_id) do
    capable(
      :portal,
      :portal_configuration,
      provider,
      tenant,
      & &1.fetch_portal_configuration(configuration_id, &2)
    )
  end

  @doc """
  One page of portal setups at `provider`, newest first (`MishkaPay.Page` of
  `MishkaPay.PortalSession.Configuration`): `active:` only those on (or off), `default: true` only the one
  a session without `:configuration` uses, plus `limit:` and `after:`.
  """
  @spec list_portal_configurations(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_portal_configurations(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(
      :portal,
      :portal_configuration_list,
      provider,
      tenant,
      & &1.list_portal_configurations(limited(opts), &2)
    )
  end

  @doc """
  One page of the payment methods customer `customer_id:` saved at `provider`
  (`MishkaPay.Page` of `MishkaPay.Customer.PaymentMethod`), plus `limit:` and `after:`. A checkout in
  `mode: :setup` saves one.
  """
  @spec list_payment_methods(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_payment_methods(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:payment_method, :payment_method_list, provider, tenant, fn module, keys ->
      case opts[:customer_id] do
        nil ->
          MishkaPay.ProviderKit.invalid(
            :customer_id,
            Messages.text(:customer_needs, field: :customer_id)
          )

        _customer_id ->
          module.list_payment_methods(limited(opts), keys)
      end
    end)
  end

  @doc "Reads saved payment method `payment_method_id` again from `provider`, with its card."
  @spec fetch_payment_method(String.t(), String.t(), term()) ::
          {:ok, Customer.PaymentMethod.t()} | {:error, Splode.Error.t()}
  def fetch_payment_method(provider, payment_method_id, tenant \\ nil)
      when is_binary(provider) and is_binary(payment_method_id) do
    capable(
      :payment_method,
      :payment_method,
      provider,
      tenant,
      & &1.fetch_payment_method(payment_method_id, &2)
    )
  end

  @doc """
  Takes saved payment method `payment_method_id` off its customer at `provider`, for good: it
  can no longer be charged or saved again. Answers it after, with no `:customer_id`.
  """
  @spec detach_payment_method(String.t(), String.t(), term()) ::
          {:ok, Customer.PaymentMethod.t()} | {:error, Splode.Error.t()}
  def detach_payment_method(provider, payment_method_id, tenant \\ nil)
      when is_binary(provider) and is_binary(payment_method_id) do
    capable(
      :payment_method,
      :payment_method_detach,
      provider,
      tenant,
      & &1.detach_payment_method(payment_method_id, &2)
    )
  end

  @doc """
  Makes saved payment method `payment_method_id` the one customer `customer_id`'s invoices and
  subscriptions charge, and answers the customer after, with its `:default_payment_method`.
  """
  @spec set_default_payment_method(String.t(), String.t(), String.t(), term()) ::
          {:ok, Customer.t()} | {:error, Splode.Error.t()}
  def set_default_payment_method(provider, customer_id, payment_method_id, tenant \\ nil)
      when is_binary(provider) and is_binary(customer_id) and is_binary(payment_method_id) do
    capable(
      :payment_method,
      :payment_method_default,
      provider,
      tenant,
      & &1.set_default_payment_method(customer_id, payment_method_id, &2)
    )
  end

  @doc """
  Ends open checkout `checkout_id` at `provider` so it can no longer be paid, and answers it
  (`status: :expired`). Call it when a buyer walks away and the stock held for them should be
  free again; a checkout already paid or expired is refused.
  """
  @spec expire_checkout(String.t(), String.t(), term()) ::
          {:ok, Checkout.t()} | {:error, Splode.Error.t()}
  def expire_checkout(provider, checkout_id, tenant \\ nil)
      when is_binary(provider) and is_binary(checkout_id) do
    capable(:expire, :checkout_expire, provider, tenant, & &1.expire_checkout(checkout_id, &2))
  end

  @doc "Makes a coupon from `attrs` (see `MishkaPay.Coupon`) at `attrs.provider`."
  @spec create_coupon(map()) :: {:ok, Coupon.t()} | {:error, Splode.Error.t()}
  def create_coupon(attrs) when is_map(attrs) do
    made(:coupon_create, :discount, attrs, Coupon, [:provider], :create_coupon)
  end

  @doc "Reads coupon `coupon_id` again from `provider`, with `tenant`'s keys."
  @spec fetch_coupon(String.t(), String.t(), term()) ::
          {:ok, Coupon.t()} | {:error, Splode.Error.t()}
  def fetch_coupon(provider, coupon_id, tenant \\ nil)
      when is_binary(provider) and is_binary(coupon_id) do
    capable(:discount, :coupon, provider, tenant, & &1.fetch_coupon(coupon_id, &2))
  end

  @doc "One page of coupons at `provider`, newest first (`MishkaPay.Page`): `limit:`, `after:`."
  @spec list_coupons(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_coupons(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:discount, :coupon_list, provider, tenant, & &1.list_coupons(limited(opts), &2))
  end

  @doc """
  Removes coupon `coupon_id` at `provider`, so no checkout or code applies it again. What it
  already took off stays taken off.
  """
  @spec delete_coupon(String.t(), String.t(), term()) :: :ok | {:error, Splode.Error.t()}
  def delete_coupon(provider, coupon_id, tenant \\ nil)
      when is_binary(provider) and is_binary(coupon_id) do
    capable(:discount, :coupon_delete, provider, tenant, & &1.delete_coupon(coupon_id, &2))
  end

  @doc "Makes a promotion code from `attrs` (see `MishkaPay.Coupon.PromotionCode`) at `attrs.provider`."
  @spec create_promotion_code(map()) ::
          {:ok, Coupon.PromotionCode.t()} | {:error, Splode.Error.t()}
  def create_promotion_code(attrs) when is_map(attrs) do
    made(
      :promotion_code_create,
      :discount,
      attrs,
      Coupon.PromotionCode,
      [:provider, :coupon_id],
      :create_promotion_code
    )
  end

  @doc "Reads promotion code `promotion_code_id` again from `provider`, with `tenant`'s keys."
  @spec fetch_promotion_code(String.t(), String.t(), term()) ::
          {:ok, Coupon.PromotionCode.t()} | {:error, Splode.Error.t()}
  def fetch_promotion_code(provider, promotion_code_id, tenant \\ nil)
      when is_binary(provider) and is_binary(promotion_code_id) do
    capable(
      :discount,
      :promotion_code,
      provider,
      tenant,
      & &1.fetch_promotion_code(promotion_code_id, &2)
    )
  end

  @doc """
  One page of promotion codes at `provider`, newest first (`MishkaPay.Page`): `code:` the code a
  buyer typed, `coupon_id:` only those of one coupon, `active:` only those that can (or cannot)
  be used now, plus `limit:` and `after:`.
  """
  @spec list_promotion_codes(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_promotion_codes(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(
      :discount,
      :promotion_code_list,
      provider,
      tenant,
      & &1.list_promotion_codes(limited(opts), &2)
    )
  end

  @doc """
  Changes promotion code `attrs.id` at `attrs.provider`: `active: false` turns it off, `true` on
  again; `:metadata` too. Its code, coupon and limits stay as made.
  """
  @spec update_promotion_code(map()) ::
          {:ok, Coupon.PromotionCode.t()} | {:error, Splode.Error.t()}
  def update_promotion_code(attrs) when is_map(attrs) do
    made(
      :promotion_code_update,
      :discount,
      attrs,
      Coupon.PromotionCode,
      [:provider, :id],
      :update_promotion_code
    )
  end

  # One call to a provider with `capability`, inside its telemetry span.
  defp capable(capability, operation, provider, tenant, call) do
    span(operation, %{provider: provider, tenant: tenant}, fn ->
      with {:ok, module} <- Provider.capable(provider, capability),
           {:ok, keys} <- Credentials.fetch(provider, tenant) do
        call.(module, keys)
      end
    end)
  end

  @doc """
  One page of payments at `provider`, newest first (`MishkaPay.Page`): `customer_id:` only one
  customer's, plus `limit:` and `after:`. Each is a `MishkaPay.Payment` as `fetch_payment/3`
  answers it.
  """
  @spec list_payments(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_payments(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:payment_list, :payment_list, provider, tenant, & &1.list_payments(limited(opts), &2))
  end

  @doc "Makes a product from `attrs` (see `MishkaPay.Product`) in `attrs.provider`'s catalog."
  @spec create_product(map()) :: {:ok, Product.t()} | {:error, Splode.Error.t()}
  def create_product(attrs) when is_map(attrs) do
    made(:product_create, :catalog, attrs, Product, [:provider, :name], :create_product)
  end

  @doc "Reads product `product_id` again from `provider`, with `tenant`'s keys."
  @spec fetch_product(String.t(), String.t(), term()) ::
          {:ok, Product.t()} | {:error, Splode.Error.t()}
  def fetch_product(provider, product_id, tenant \\ nil)
      when is_binary(provider) and is_binary(product_id) do
    capable(:catalog, :product, provider, tenant, & &1.fetch_product(product_id, &2))
  end

  @doc "Changes product `attrs.id` at `attrs.provider`: only the fields given are sent."
  @spec update_product(map()) :: {:ok, Product.t()} | {:error, Splode.Error.t()}
  def update_product(attrs) when is_map(attrs) do
    made(:product_update, :catalog, attrs, Product, [:provider, :id], :update_product)
  end

  @doc """
  Takes product `product_id` off sale (`active: false`). Past sales keep it; a provider never
  deletes a product that sold.
  """
  @spec archive_product(String.t(), String.t(), term()) ::
          {:ok, Product.t()} | {:error, Splode.Error.t()}
  def archive_product(provider, product_id, tenant \\ nil)
      when is_binary(provider) and is_binary(product_id) do
    update_product(%{provider: provider, tenant: tenant, id: product_id, active: false})
  end

  @doc """
  One page of products at `provider`, newest first (`MishkaPay.Page`): `active:` only those on (or
  off) sale, plus `limit:` and `after:`.
  """
  @spec list_products(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_products(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:catalog, :product_list, provider, tenant, & &1.list_products(limited(opts), &2))
  end

  @doc """
  Makes a price of product `attrs.product_id` from `attrs` (see `MishkaPay.Price`): an `:amount`,
  and an `:interval` for a plan.
  """
  @spec create_price(map()) :: {:ok, Price.t()} | {:error, Splode.Error.t()}
  def create_price(attrs) when is_map(attrs) do
    made(:price_create, :catalog, attrs, Price, [:provider, :product_id, :amount], :create_price)
  end

  @doc "Reads price `price_id` again from `provider`, with `tenant`'s keys."
  @spec fetch_price(String.t(), String.t(), term()) ::
          {:ok, Price.t()} | {:error, Splode.Error.t()}
  def fetch_price(provider, price_id, tenant \\ nil)
      when is_binary(provider) and is_binary(price_id) do
    capable(:catalog, :price, provider, tenant, & &1.fetch_price(price_id, &2))
  end

  @doc """
  Takes price `price_id` off sale (`active: false`): a checkout can no longer sell it. A provider
  never deletes a price that was used.
  """
  @spec archive_price(String.t(), String.t(), term()) ::
          {:ok, Price.t()} | {:error, Splode.Error.t()}
  def archive_price(provider, price_id, tenant \\ nil)
      when is_binary(provider) and is_binary(price_id) do
    attrs = %{provider: provider, tenant: tenant, id: price_id, active: false}
    made(:price_update, :catalog, attrs, Price, [:provider, :id], :update_price)
  end

  @doc """
  One page of prices at `provider`, newest first (`MishkaPay.Page`): `product_id:` only one
  product's, `lookup_key:` the price the host named so, `active:` only those on (or off) sale,
  plus `limit:` and `after:`.
  """
  @spec list_prices(String.t(), term(), keyword()) :: {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_prices(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:catalog, :price_list, provider, tenant, & &1.list_prices(limited(opts), &2))
  end

  @doc """
  Makes a payment link from `attrs` (see `MishkaPay.PaymentLink`): catalog prices by id, sold to
  anyone who opens its `:url`.
  """
  @spec create_payment_link(map()) :: {:ok, PaymentLink.t()} | {:error, Splode.Error.t()}
  def create_payment_link(attrs) when is_map(attrs) do
    made(
      :payment_link_create,
      :payment_link,
      attrs,
      PaymentLink,
      [:provider, :items],
      :create_payment_link
    )
  end

  @doc "Reads payment link `payment_link_id` again from `provider`, with `tenant`'s keys."
  @spec fetch_payment_link(String.t(), String.t(), term()) ::
          {:ok, PaymentLink.t()} | {:error, Splode.Error.t()}
  def fetch_payment_link(provider, payment_link_id, tenant \\ nil)
      when is_binary(provider) and is_binary(payment_link_id) do
    capable(
      :payment_link,
      :payment_link,
      provider,
      tenant,
      & &1.fetch_payment_link(payment_link_id, &2)
    )
  end

  @doc """
  Changes payment link `attrs.id` at `attrs.provider`: `active: false` turns it off and `true` on
  again, and any other option given (`:max_purchases`, `:inactive_message`, `:success_url`,
  `:allow_promotion_codes`...) is changed too; its prices and trial stay as made. A link cannot be
  deleted; a turned-off one refuses buyers.
  """
  @spec update_payment_link(map()) :: {:ok, PaymentLink.t()} | {:error, Splode.Error.t()}
  def update_payment_link(attrs) when is_map(attrs) do
    made(
      :payment_link_update,
      :payment_link,
      attrs,
      PaymentLink,
      [:provider, :id],
      :update_payment_link
    )
  end

  @doc """
  One page of payment links at `provider`, newest first (`MishkaPay.Page`): `active:` only those
  on (or off), plus `limit:` and `after:`.
  """
  @spec list_payment_links(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_payment_links(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(
      :payment_link,
      :payment_link_list,
      provider,
      tenant,
      & &1.list_payment_links(limited(opts), &2)
    )
  end

  @doc "Reads dispute `dispute_id` from `provider`, with `tenant`'s keys."
  @spec fetch_dispute(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Dispute.t()} | {:error, Splode.Error.t()}
  def fetch_dispute(provider, dispute_id, tenant \\ nil)
      when is_binary(provider) and is_binary(dispute_id) do
    capable(:dispute, :dispute, provider, tenant, & &1.fetch_dispute(dispute_id, &2))
  end

  @doc """
  One page of disputes at `provider`, newest first (`MishkaPay.Page`): `payment_id:` only one
  payment's, plus `limit:` and `after:`.
  """
  @spec list_disputes(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_disputes(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:dispute, :dispute_list, provider, tenant, & &1.list_disputes(limited(opts), &2))
  end

  @doc """
  Answers a dispute with evidence (see `MishkaPay.Dispute.Evidence`): kept to add more, or sent to
  the bank with `submit: true`. Answers the dispute after.
  """
  @spec update_dispute(map()) :: {:ok, MishkaPay.Dispute.t()} | {:error, Splode.Error.t()}
  def update_dispute(attrs) when is_map(attrs) do
    span(:dispute_update, attrs, fn ->
      with {:ok, evidence} <- Errors.from_builder(MishkaPay.Dispute.Evidence.builder(attrs)),
           {:ok, module} <- Provider.capable(evidence.provider, :dispute),
           {:ok, keys} <- Credentials.fetch(evidence.provider, evidence.tenant) do
        module.update_dispute(evidence, keys)
      end
    end)
  end

  @doc "Accepts dispute `dispute_id`: the seller does not contest it, and it closes as lost."
  @spec accept_dispute(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Dispute.t()} | {:error, Splode.Error.t()}
  def accept_dispute(provider, dispute_id, tenant \\ nil)
      when is_binary(provider) and is_binary(dispute_id) do
    capable(:dispute, :dispute_accept, provider, tenant, & &1.accept_dispute(dispute_id, &2))
  end

  @doc """
  Reads early fraud warning `warning_id` (`MishkaPay.Payment.FraudWarning`): a card issuer saying a
  payment looks like fraud, before any dispute.
  """
  @spec fetch_fraud_warning(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Payment.FraudWarning.t()} | {:error, Splode.Error.t()}
  def fetch_fraud_warning(provider, warning_id, tenant \\ nil)
      when is_binary(provider) and is_binary(warning_id) do
    capable(:fraud, :fraud_warning, provider, tenant, & &1.fetch_fraud_warning(warning_id, &2))
  end

  @doc """
  One page of early fraud warnings, newest first (`MishkaPay.Page` of `MishkaPay.Payment.FraudWarning`):
  `payment_id:` or `charge_id:` only those about one payment, plus `limit:` and `after:`. A
  warning that is `:actionable` can still be headed off: refund its payment in full.
  """
  @spec list_fraud_warnings(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_fraud_warnings(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(
      :fraud,
      :fraud_warning_list,
      provider,
      tenant,
      & &1.list_fraud_warnings(limited(opts), &2)
    )
  end

  @doc "Reads review `review_id` (`MishkaPay.Payment.FraudReview`), open or closed."
  @spec fetch_fraud_review(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Payment.FraudReview.t()} | {:error, Splode.Error.t()}
  def fetch_fraud_review(provider, review_id, tenant \\ nil)
      when is_binary(provider) and is_binary(review_id) do
    capable(:fraud, :fraud_review, provider, tenant, & &1.fetch_fraud_review(review_id, &2))
  end

  @doc """
  One page of the reviews still open, newest first (`MishkaPay.Page` of `MishkaPay.Payment.FraudReview`):
  payments the provider's fraud rules hold for the seller, plus `limit:` and `after:`.
  """
  @spec list_fraud_reviews(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_fraud_reviews(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(
      :fraud,
      :fraud_review_list,
      provider,
      tenant,
      & &1.list_fraud_reviews(limited(opts), &2)
    )
  end

  @doc """
  Approves open review `review_id`: the seller trusts the payment and it goes on. Answers the
  review, closed. To turn it down instead, refund the payment.
  """
  @spec approve_fraud_review(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Payment.FraudReview.t()} | {:error, Splode.Error.t()}
  def approve_fraud_review(provider, review_id, tenant \\ nil)
      when is_binary(provider) and is_binary(review_id) do
    capable(
      :fraud,
      :fraud_review_approve,
      provider,
      tenant,
      & &1.approve_fraud_review(review_id, &2)
    )
  end

  @doc """
  Uploads a file from `attrs` (see `MishkaPay.File.Upload`): a receipt, a download log or a
  screenshot that answers a dispute. Answers it as a `MishkaPay.File`; put its `:id` in the
  dispute's evidence with `update_dispute/1`.
  """
  @spec upload_file(map()) :: {:ok, MishkaPay.File.t()} | {:error, Splode.Error.t()}
  def upload_file(attrs) when is_map(attrs),
    do: made(:file_upload, :file, attrs, MishkaPay.File.Upload, [], :upload_file)

  @doc "Reads file `file_id` from `provider`, with `tenant`'s keys."
  @spec fetch_file(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.File.t()} | {:error, Splode.Error.t()}
  def fetch_file(provider, file_id, tenant \\ nil)
      when is_binary(provider) and is_binary(file_id) do
    capable(:file, :file, provider, tenant, & &1.fetch_file(file_id, &2))
  end

  @doc """
  Makes a public link to file `file_id` (`MishkaPay.File.Link`), an address a site can show to a
  person without any key. `expires_at:` (a `DateTime` still to come) ends it; without it, it
  never ends.
  """
  @spec file_link(String.t(), String.t(), term(), keyword()) ::
          {:ok, MishkaPay.File.Link.t()} | {:error, Splode.Error.t()}
  def file_link(provider, file_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(file_id) do
    capable(:file, :file_link, provider, tenant, & &1.file_link(file_id, opts, &2))
  end

  @doc """
  Makes a meter from `attrs` (see `MishkaPay.Meter`): its `:event_name`, a `:name`, and its
  `:aggregation` (`:sum`, `:count` or `:last`). A price with its `:meter_id` and an `:interval`
  bills what it counts.
  """
  @spec create_meter(map()) :: {:ok, MishkaPay.Meter.t()} | {:error, Splode.Error.t()}
  def create_meter(attrs) when is_map(attrs) do
    made(:meter_create, :usage, attrs, MishkaPay.Meter, [:provider, :event_name], :create_meter)
  end

  @doc """
  One page of meters at `provider` (`MishkaPay.Page`): `status:` only `:active` or `:inactive`
  ones, plus `limit:` and `after:`.
  """
  @spec list_meters(String.t(), term(), keyword()) :: {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_meters(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:usage, :meter_list, provider, tenant, & &1.list_meters(limited(opts), &2))
  end

  @doc """
  Turns meter `meter_id` off: it takes no more usage, and no new price can bill it. A provider
  never deletes a meter.
  """
  @spec deactivate_meter(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Meter.t()} | {:error, Splode.Error.t()}
  def deactivate_meter(provider, meter_id, tenant \\ nil)
      when is_binary(provider) and is_binary(meter_id) do
    capable(:usage, :meter_deactivate, provider, tenant, & &1.deactivate_meter(meter_id, &2))
  end

  @doc "Turns meter `meter_id` on again after `deactivate_meter/3`: it takes usage and prices again."
  @spec reactivate_meter(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Meter.t()} | {:error, Splode.Error.t()}
  def reactivate_meter(provider, meter_id, tenant \\ nil)
      when is_binary(provider) and is_binary(meter_id) do
    capable(:usage, :meter_reactivate, provider, tenant, & &1.reactivate_meter(meter_id, &2))
  end

  @doc "Reads meter `meter_id` again from `provider`, with `tenant`'s keys."
  @spec fetch_meter(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Meter.t()} | {:error, Splode.Error.t()}
  def fetch_meter(provider, meter_id, tenant \\ nil)
      when is_binary(provider) and is_binary(meter_id) do
    capable(:usage, :meter, provider, tenant, & &1.fetch_meter(meter_id, &2))
  end

  @doc """
  Renames meter `:id` to `:name` (see `MishkaPay.Meter`). Its event name and how it adds up never
  change: make a new meter for that.
  """
  @spec update_meter(map()) :: {:ok, MishkaPay.Meter.t()} | {:error, Splode.Error.t()}
  def update_meter(attrs) when is_map(attrs) do
    made(:meter_update, :usage, attrs, MishkaPay.Meter, [:provider, :id, :name], :update_meter)
  end

  @doc """
  Reports what a customer used, from `attrs` (see `MishkaPay.Usage`): the meter's
  `:event_name`, the `:customer_id`, a `:value`, when it happened (`:at`) and a `:reference`, so
  the same use never counts twice.
  """
  @spec report_usage(map()) :: {:ok, MishkaPay.Usage.t()} | {:error, Splode.Error.t()}
  def report_usage(attrs) when is_map(attrs) do
    made(:usage_report, :usage, attrs, MishkaPay.Usage, [:provider], :report_usage)
  end

  @doc """
  Takes back a usage report sent by mistake, from `attrs` (see `MishkaPay.Usage.Cancellation`):
  the meter's `:event_name` and the report's `:usage_id` (the `:id` `report_usage/1` answered).
  The same cancel sent again is one cancel. A provider takes a report back only for a while
  (Stripe: 24 hours); after that, report the value again below zero.

      {:ok, usage} = MishkaPay.report_usage(%{..., reference: "req-42"})
      MishkaPay.cancel_usage(%{provider: "stripe", tenant: site_id, event_name: "api_call",
                               usage_id: usage.id})
  """
  @spec cancel_usage(map()) ::
          {:ok, MishkaPay.Usage.Cancellation.t()} | {:error, Splode.Error.t()}
  def cancel_usage(attrs) when is_map(attrs) do
    made(:usage_cancel, :usage, attrs, MishkaPay.Usage.Cancellation, [:provider], :cancel_usage)
  end

  @doc """
  What meter `meter_id` counted for `customer_id` from `from` to `to` (`DateTime`s, `to` not
  included), as one `MishkaPay.Usage.Summary`. A use reported a moment ago may not be counted yet.
  """
  @spec usage_summary(String.t(), String.t(), String.t(), DateTime.t(), DateTime.t(), term()) ::
          {:ok, MishkaPay.Usage.Summary.t()} | {:error, Splode.Error.t()}
  def usage_summary(provider, meter_id, customer_id, from, to, tenant \\ nil)
      when is_binary(provider) and is_binary(meter_id) and is_binary(customer_id) and
             is_struct(from, DateTime) and is_struct(to, DateTime) do
    capable(:usage, :usage_summary, provider, tenant, fn module, keys ->
      case DateTime.compare(from, to) do
        :lt ->
          module.usage_summary(meter_id, [customer_id: customer_id, from: from, to: to], keys)

        _not_after ->
          MishkaPay.ProviderKit.invalid(:to, Messages.text(:usage_window))
      end
    end)
  end

  @doc """
  Makes a feature from `attrs` (see `MishkaPay.Feature`): a `:name` and the `:lookup_key` the
  host checks access by.
  """
  @spec create_feature(map()) :: {:ok, MishkaPay.Feature.t()} | {:error, Splode.Error.t()}
  def create_feature(attrs) when is_map(attrs) do
    needed = [:provider, :name, :lookup_key]
    made(:feature_create, :entitlement, attrs, MishkaPay.Feature, needed, :create_feature)
  end

  @doc """
  Attaches feature `feature_id` to catalog product `product_id`: a customer who buys the product
  is entitled to the feature. Answers the feature.
  """
  @spec attach_feature(String.t(), String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Feature.t()} | {:error, Splode.Error.t()}
  def attach_feature(provider, product_id, feature_id, tenant \\ nil)
      when is_binary(provider) and is_binary(product_id) and is_binary(feature_id) do
    capable(
      :entitlement,
      :feature_attach,
      provider,
      tenant,
      & &1.attach_feature(product_id, feature_id, &2)
    )
  end

  @doc """
  One page of the features customer `customer_id` may use now (`MishkaPay.Page` of
  `MishkaPay.Feature.Entitlement`), plus `limit:` and `after:`. Check access by their `:lookup_key`.
  """
  @spec list_entitlements(String.t(), String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_entitlements(provider, customer_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(customer_id) do
    opts = opts |> limited() |> Keyword.put(:customer_id, customer_id)
    capable(:entitlement, :entitlement_list, provider, tenant, & &1.list_entitlements(opts, &2))
  end

  @doc "The seller's balance at `provider` (`MishkaPay.Balance`): available and pending, per currency."
  @spec fetch_balance(String.t(), term()) ::
          {:ok, MishkaPay.Balance.t()} | {:error, Splode.Error.t()}
  def fetch_balance(provider, tenant \\ nil) when is_binary(provider) do
    capable(:balance, :balance, provider, tenant, fn module, keys ->
      module.fetch_balance(keys)
    end)
  end

  @doc """
  One page of the movements of the seller's balance, newest first (`MishkaPay.Page` of
  `MishkaPay.Balance.Transaction`): `payout_id:` those one payout paid out, `type:` only one kind
  (the provider's name, such as `"charge"`), plus `limit:` and `after:`.
  """
  @spec list_balance_transactions(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_balance_transactions(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(
      :balance,
      :balance_transaction_list,
      provider,
      tenant,
      & &1.list_balance_transactions(limited(opts), &2)
    )
  end

  @doc """
  Changes customer `customer_id`'s balance by `money` (a `Money`, or a map with `:amount` and
  `:currency`): below zero gives credit taken off their next bills, above zero adds a debit.
  `description:` says why; `reference:` makes it happen once. Answers the
  `MishkaPay.Customer.BalanceTransaction` with the balance after.
  """
  @spec adjust_customer_balance(String.t(), String.t(), Money.t() | map(), term(), keyword()) ::
          {:ok, MishkaPay.Customer.BalanceTransaction.t()} | {:error, Splode.Error.t()}
  def adjust_customer_balance(provider, customer_id, money, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(customer_id) do
    attrs = %{
      provider: provider,
      tenant: tenant,
      customer_id: customer_id,
      amount: money,
      description: opts[:description],
      reference: opts[:reference]
    }

    made(
      :customer_balance_adjust,
      :customer_balance,
      attrs,
      MishkaPay.Customer.BalanceTransaction,
      [:provider],
      :adjust_customer_balance
    )
  end

  @doc """
  One page of the changes to customer `customer_id`'s balance, newest first (`MishkaPay.Page` of
  `MishkaPay.Customer.BalanceTransaction`), plus `limit:` and `after:`.
  """
  @spec list_customer_balance(String.t(), String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_customer_balance(provider, customer_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(customer_id) do
    opts = opts |> limited() |> Keyword.put(:customer_id, customer_id)

    capable(
      :customer_balance,
      :customer_balance_list,
      provider,
      tenant,
      & &1.list_customer_balance(opts, &2)
    )
  end

  @doc """
  Makes a connected account for a seller from `attrs` (see `MishkaPay.ConnectedAccount`), with
  the platform's keys: `:configurations` (`[:merchant, :recipient]` by default), `:dashboard`
  (`:express` by default), `:country`, `:email`, `:capabilities`, `:api` (else the tenant's
  `:connect_api`, `:v2` by default) and a `:reference` that makes it once. Then send the seller to `account_link/1`, and give the
  seller's site its id as `:account_id` in its keys.
  """
  @spec create_connected_account(map()) ::
          {:ok, MishkaPay.ConnectedAccount.t()} | {:error, Splode.Error.t()}
  def create_connected_account(attrs) when is_map(attrs) do
    made(
      :connected_account_create,
      :connect,
      attrs,
      MishkaPay.ConnectedAccount,
      [:provider],
      :create_connected_account
    )
  end

  @doc """
  Reads connected account `account_id` (`MishkaPay.ConnectedAccount`): whether it can take
  payments, payouts and transfers yet, and what the provider still needs from the seller.
  `api:` reads it with `:v2` or `:v1` instead of the tenant's `:connect_api` (at Stripe either
  reads an account made with either).
  """
  @spec fetch_connected_account(String.t(), String.t(), term(), keyword()) ::
          {:ok, MishkaPay.ConnectedAccount.t()} | {:error, Splode.Error.t()}
  def fetch_connected_account(provider, account_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(account_id) do
    capable(
      :connect,
      :connected_account,
      provider,
      tenant,
      & &1.fetch_connected_account(account_id, opts, &2)
    )
  end

  @doc """
  Changes the connected account `attrs` names by `:id`: the `:email`, `:business_name`,
  `:configurations` and `:capabilities` (asked for on top of those it has) or `:metadata` given.
  Answers it after.
  """
  @spec update_connected_account(map()) ::
          {:ok, MishkaPay.ConnectedAccount.t()} | {:error, Splode.Error.t()}
  def update_connected_account(attrs) when is_map(attrs) do
    made(
      :connected_account_update,
      :connect,
      attrs,
      MishkaPay.ConnectedAccount,
      [:provider, :id],
      :update_connected_account
    )
  end

  @doc """
  One page of the platform's connected accounts, newest first (`MishkaPay.Page` of
  `MishkaPay.ConnectedAccount`), with `limit:` and `after:`, and `api:` (`:v2` or `:v1`, else
  the tenant's `:connect_api`). A Stripe v2 page holds at most 20. On v2 also `configurations:` (only accounts with all of them)
  and `closed: true` (only closed ones; left out, only open ones); each account answers its own
  fields only, so read one for its states.
  """
  @spec list_connected_accounts(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_connected_accounts(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(
      :connect,
      :connected_account_list,
      provider,
      tenant,
      & &1.list_connected_accounts(limited(opts), &2)
    )
  end

  @doc """
  Closes connected account `account_id` for good: it takes no more payments or payouts, and is
  still read with `closed: true`. `api:` as in `fetch_connected_account/4`. At Stripe on v2 the
  account is read first, since Stripe closes it only with every configuration it has; on v1 it
  is turned down (rejected) with `reason:` (`"fraud_other"`, `"terms_of_service"`, `"credit"`,
  `"other"`...; `"other"` when left out). Answers the account after.
  """
  @spec close_connected_account(String.t(), String.t(), term(), keyword()) ::
          {:ok, MishkaPay.ConnectedAccount.t()} | {:error, Splode.Error.t()}
  def close_connected_account(provider, account_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(account_id) do
    capable(
      :connect,
      :connected_account_close,
      provider,
      tenant,
      & &1.close_connected_account(account_id, opts, &2)
    )
  end

  @doc """
  Makes a one-time link (`MishkaPay.ConnectedAccount.Link`) that sends a seller to the provider's pages for
  their connected account: `:account_id`, `:type` (`:onboarding` or `:update`), `:refresh_url`
  and `:return_url`. Redirect the seller to its `:url` at once; it runs out in minutes.
  """
  @spec account_link(map()) ::
          {:ok, MishkaPay.ConnectedAccount.Link.t()} | {:error, Splode.Error.t()}
  def account_link(attrs) when is_map(attrs) do
    made(
      :account_link,
      :connect,
      attrs,
      MishkaPay.ConnectedAccount.Link,
      [:provider, :account_id],
      :account_link
    )
  end

  @doc """
  Makes a one-time link into connected account `account_id`'s own dashboard at the provider
  (`MishkaPay.ConnectedAccount.Link`, `type: :login`), for a seller who finished onboarding.
  """
  @spec login_link(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.ConnectedAccount.Link.t()} | {:error, Splode.Error.t()}
  def login_link(provider, account_id, tenant \\ nil)
      when is_binary(provider) and is_binary(account_id) do
    capable(:connect, :login_link, provider, tenant, & &1.login_link(account_id, &2))
  end

  @doc """
  Reads application fee `fee_id` (`MishkaPay.ApplicationFee`): the platform's cut of a seller's
  sale, and what of it was given back.
  """
  @spec fetch_application_fee(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.ApplicationFee.t()} | {:error, Splode.Error.t()}
  def fetch_application_fee(provider, fee_id, tenant \\ nil)
      when is_binary(provider) and is_binary(fee_id) do
    capable(:connect, :application_fee, provider, tenant, & &1.fetch_application_fee(fee_id, &2))
  end

  @doc """
  One page of the platform's application fees, newest first (`MishkaPay.Page` of
  `MishkaPay.ApplicationFee`): `charge_id:` only one sale's, plus `limit:` and `after:`.
  """
  @spec list_application_fees(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_application_fees(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(
      :connect,
      :application_fee_list,
      provider,
      tenant,
      & &1.list_application_fees(limited(opts), &2)
    )
  end

  @doc """
  Gives application fee `fee_id` back to the seller: all of it, or `amount:` (money in the fee's
  currency). `reference:` makes it once. Answers the fee after, with `:amount_refunded`.
  """
  @spec refund_application_fee(String.t(), String.t(), term(), keyword()) ::
          {:ok, MishkaPay.ApplicationFee.t()} | {:error, Splode.Error.t()}
  def refund_application_fee(provider, fee_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(fee_id) do
    capable(:connect, :application_fee_refund, provider, tenant, fn module, keys ->
      with {:ok, amount} <- part_amount(opts[:amount]),
           do: module.refund_application_fee(fee_id, part(opts, amount, tenant), keys)
    end)
  end

  @doc """
  Sends money from the platform's balance to a connected account, from `attrs` (see
  `MishkaPay.Transfer`): `:amount`, `:destination` and a `:reference` that sends it once.
  """
  @spec create_transfer(map()) :: {:ok, MishkaPay.Transfer.t()} | {:error, Splode.Error.t()}
  def create_transfer(attrs) when is_map(attrs) do
    made(
      :transfer_create,
      :transfer,
      attrs,
      MishkaPay.Transfer,
      [:provider, :amount, :destination, :reference],
      :create_transfer
    )
  end

  @doc "Reads transfer `transfer_id` (`MishkaPay.Transfer`), with what was taken back of it."
  @spec fetch_transfer(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Transfer.t()} | {:error, Splode.Error.t()}
  def fetch_transfer(provider, transfer_id, tenant \\ nil)
      when is_binary(provider) and is_binary(transfer_id) do
    capable(:transfer, :transfer, provider, tenant, & &1.fetch_transfer(transfer_id, &2))
  end

  @doc """
  One page of the platform's transfers, newest first (`MishkaPay.Page` of `MishkaPay.Transfer`):
  `destination:` only those to one connected account, `transfer_group:` one order's, plus
  `limit:` and `after:`.
  """
  @spec list_transfers(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_transfers(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:transfer, :transfer_list, provider, tenant, & &1.list_transfers(limited(opts), &2))
  end

  @doc """
  Takes transfer `transfer_id` back from its connected account: all of it, or `amount:` (money
  in the transfer's currency). `reference:` makes it once. Answers the transfer after, with
  `:amount_reversed`.
  """
  @spec reverse_transfer(String.t(), String.t(), term(), keyword()) ::
          {:ok, MishkaPay.Transfer.t()} | {:error, Splode.Error.t()}
  def reverse_transfer(provider, transfer_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(transfer_id) do
    capable(:transfer, :transfer_reverse, provider, tenant, fn module, keys ->
      with {:ok, amount} <- part_amount(opts[:amount]),
           do: module.reverse_transfer(transfer_id, part(opts, amount, tenant), keys)
    end)
  end

  @doc """
  Reads payout `payout_id` (`MishkaPay.Balance.Payout`) of the account `tenant`'s keys act for: the
  platform's own, or the connected account they name.
  """
  @spec fetch_payout(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Balance.Payout.t()} | {:error, Splode.Error.t()}
  def fetch_payout(provider, payout_id, tenant \\ nil)
      when is_binary(provider) and is_binary(payout_id) do
    capable(:payout, :payout, provider, tenant, & &1.fetch_payout(payout_id, &2))
  end

  @doc """
  One page of payouts, newest first (`MishkaPay.Page` of `MishkaPay.Balance.Payout`): `status:` only
  `:pending`, `:in_transit`, `:paid`, `:failed` or `:canceled` ones, plus `limit:` and `after:`.
  """
  @spec list_payouts(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_payouts(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:payout, :payout_list, provider, tenant, fn module, keys ->
      case opts[:status] in [nil, :pending, :in_transit, :paid, :failed, :canceled] do
        true ->
          module.list_payouts(limited(opts), keys)

        false ->
          ProviderKit.invalid(
            :status,
            Messages.text(:choices,
              field: :status,
              choices: "pending, in_transit, paid, failed, canceled"
            )
          )
      end
    end)
  end

  @doc "Stops payout `payout_id` while it is still `:pending`; answers it `:canceled`."
  @spec cancel_payout(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Balance.Payout.t()} | {:error, Splode.Error.t()}
  def cancel_payout(provider, payout_id, tenant \\ nil)
      when is_binary(provider) and is_binary(payout_id) do
    capable(:payout, :payout_cancel, provider, tenant, & &1.cancel_payout(payout_id, &2))
  end

  @doc """
  Pays money of the available balance out to the bank or card of the account `attrs.tenant`'s keys
  act for, now (see `MishkaPay.Balance.Payout`): `:amount` above zero and a `:reference` that pays
  it out once, with `:method` (`"standard"` or `"instant"`, the provider's default when left out),
  `:destination_id`, `:statement_descriptor`, `:description` and `:metadata`. Answers the payout,
  `:pending` until it reaches the bank. Money the balance does not hold is the provider's refusal
  (`Errors.Rejected`, at Stripe with code `"balance_insufficient"`).
  """
  @spec create_payout(map()) :: {:ok, MishkaPay.Balance.Payout.t()} | {:error, Splode.Error.t()}
  def create_payout(attrs) when is_map(attrs) do
    span(:payout_create, attrs, fn ->
      with {:ok, payout} <-
             built(MishkaPay.Balance.Payout.builder(attrs), [:provider, :amount, :reference]),
           {:ok, _amount} <- part_amount(payout.amount),
           {:ok, module} <- Provider.capable(payout.provider, :payout),
           {:ok, keys} <- Credentials.fetch(payout.provider, payout.tenant) do
        module.create_payout(payout, keys)
      end
    end)
  end

  @doc """
  When the balance of the account `tenant`'s keys act for is paid out by itself
  (`MishkaPay.Balance.PayoutSchedule`): its interval and days, how many days a payment's money
  waits, the money kept back, and the smallest payout when the provider says.
  """
  @spec fetch_payout_schedule(String.t(), term()) ::
          {:ok, MishkaPay.Balance.PayoutSchedule.t()} | {:error, Splode.Error.t()}
  def fetch_payout_schedule(provider, tenant \\ nil) when is_binary(provider) do
    capable(:payout_schedule, :payout_schedule, provider, tenant, fn module, keys ->
      module.fetch_payout_schedule(keys)
    end)
  end

  @doc """
  Changes when the balance is paid out, from `attrs` (see `MishkaPay.Balance.PayoutSchedule`):
  only the fields given, such as `interval: :weekly, weekly_days: [:monday]`, `delay_days: 7`
  (`:default` for the provider's own), `minimum_balances:` or `statement_descriptor:`. A weekly
  interval needs its days, a monthly one its days of the month. Answers the whole schedule after.
  """
  @spec update_payout_schedule(map()) ::
          {:ok, MishkaPay.Balance.PayoutSchedule.t()} | {:error, Splode.Error.t()}
  def update_payout_schedule(attrs) when is_map(attrs) do
    span(:payout_schedule_update, attrs, fn ->
      with {:ok, schedule} <- built(MishkaPay.Balance.PayoutSchedule.builder(attrs), [:provider]),
           :ok <- MishkaPay.Balance.schedule_days(schedule),
           {:ok, module} <- Provider.capable(schedule.provider, :payout_schedule),
           {:ok, keys} <- Credentials.fetch(schedule.provider, schedule.tenant) do
        module.update_payout_schedule(schedule, keys)
      end
    end)
  end

  @doc """
  One page of the bank accounts and cards the account `tenant`'s keys act for is paid out to
  (`MishkaPay.Page` of `MishkaPay.Balance.PayoutDestination`, with the bank's name and the last four
  digits): `type:` `:bank_account` or `:card` only, plus `limit:` and `after:`.
  """
  @spec list_payout_destinations(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_payout_destinations(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:payout_destination, :payout_destination_list, provider, tenant, fn module, keys ->
      case opts[:type] in [nil, :bank_account, :card] do
        true ->
          module.list_payout_destinations(limited(opts), keys)

        false ->
          ProviderKit.invalid(
            :type,
            Messages.text(:choices, field: :type, choices: "bank_account, card")
          )
      end
    end)
  end

  @doc """
  Reads bank account or card `destination_id` (`MishkaPay.Balance.PayoutDestination`) the account
  `tenant`'s keys act for is paid out to, such as a payout's `:destination_id`.
  """
  @spec fetch_payout_destination(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Balance.PayoutDestination.t()} | {:error, Splode.Error.t()}
  def fetch_payout_destination(provider, destination_id, tenant \\ nil)
      when is_binary(provider) and is_binary(destination_id) do
    capable(
      :payout_destination,
      :payout_destination,
      provider,
      tenant,
      & &1.fetch_payout_destination(destination_id, &2)
    )
  end

  # The options of a part given back: its checked amount, and the tenant its reference is for.
  defp part(opts, amount, tenant),
    do: opts |> Keyword.take([:reference]) |> Keyword.merge(amount: amount, tenant: tenant)

  # A struct built from the caller's map and handed to the provider's `callback`.
  defp made(operation, capability, attrs, struct_module, needed, callback) do
    span(operation, attrs, fn ->
      with {:ok, struct} <- built(struct_module.builder(attrs), needed),
           {:ok, module} <- Provider.capable(struct.provider, capability),
           {:ok, keys} <- Credentials.fetch(struct.provider, struct.tenant) do
        apply(module, callback, [struct, keys])
      end
    end)
  end

  defp limited(opts),
    do: Keyword.put(opts, :limit, opts |> Keyword.get(:limit, 10) |> min(100) |> max(1))

  # A struct built from a caller's map, with the fields this call cannot go without.
  defp built(result, needed) do
    with {:ok, struct} <- Errors.from_builder(result) do
      case Enum.find(needed, &is_nil(Map.get(struct, &1))) do
        nil ->
          {:ok, struct}

        field ->
          MishkaPay.ProviderKit.invalid(field, Messages.text(:customer_needs, field: field))
      end
    end
  end

  @doc """
  One page of `provider`'s customers that match every filter given (`MishkaPay.Page`): `email:`,
  `name:`, `reference:` (the host's own id given when the customer was made), plus `limit:` and
  `after:`. A customer just made may take a minute to be found. `api:` (else the tenant's
  `:customer_api`) is the API the found customers are named by: Stripe searches its Customers,
  which include those made on Accounts v2, and on `:v2` each of those answers its account id.
  """
  @spec search_customers(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def search_customers(provider, tenant \\ nil, opts) when is_binary(provider) do
    capable(
      :customer,
      :customer_search,
      provider,
      tenant,
      & &1.search_customers(limited(opts), &2)
    )
  end

  @doc "The bill subscription `subscription_id` will make next, as the provider counts it now."
  @spec upcoming_invoice(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}
  def upcoming_invoice(provider, subscription_id, tenant \\ nil)
      when is_binary(provider) and is_binary(subscription_id) do
    subscription(:invoice_upcoming, provider, tenant, & &1.upcoming_invoice(subscription_id, &2))
  end

  @doc """
  Makes a draft bill for a customer from `attrs` (see `MishkaPay.Invoice.Draft`), with its items,
  and answers it as a `MishkaPay.Invoice`. Open it with `finalize_invoice/3`.
  """
  @spec create_invoice(map()) :: {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}
  def create_invoice(attrs) when is_map(attrs) do
    span(:invoice_create, attrs, fn ->
      with {:ok, draft} <- Errors.from_builder(MishkaPay.Invoice.Draft.builder(attrs)),
           {:ok, module} <- Provider.capable(draft.provider, :invoice),
           {:ok, keys} <- Credentials.fetch(draft.provider, draft.tenant) do
        module.create_invoice(draft, keys)
      end
    end)
  end

  @doc "Opens draft bill `invoice_id` for payment: it gets its number, and its customer can pay it."
  @spec finalize_invoice(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}
  def finalize_invoice(provider, invoice_id, tenant \\ nil) when is_binary(invoice_id),
    do: invoice_call(:invoice_finalize, provider, tenant, & &1.finalize_invoice(invoice_id, &2))

  @doc "Emails open bill `invoice_id` to its customer, with the provider's page to pay it."
  @spec send_invoice(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}
  def send_invoice(provider, invoice_id, tenant \\ nil) when is_binary(invoice_id),
    do: invoice_call(:invoice_send, provider, tenant, & &1.send_invoice(invoice_id, &2))

  @doc """
  Settles open bill `invoice_id`: charges the customer's saved payment method now, or with
  `out_of_band: true` marks it paid by other means (cash, a bank transfer seen by hand).
  """
  @spec pay_invoice(String.t(), String.t(), term(), keyword()) ::
          {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}
  def pay_invoice(provider, invoice_id, tenant \\ nil, opts \\ []) when is_binary(invoice_id),
    do: invoice_call(:invoice_pay, provider, tenant, & &1.pay_invoice(invoice_id, opts, &2))

  @doc "Voids open bill `invoice_id`: it stays on record and can no longer be paid."
  @spec void_invoice(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}
  def void_invoice(provider, invoice_id, tenant \\ nil) when is_binary(invoice_id),
    do: invoice_call(:invoice_void, provider, tenant, & &1.void_invoice(invoice_id, &2))

  @doc "Marks open bill `invoice_id` as one that will not be paid; it can still be paid later."
  @spec mark_invoice_uncollectible(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}
  def mark_invoice_uncollectible(provider, invoice_id, tenant \\ nil)
      when is_binary(invoice_id) do
    invoice_call(
      :invoice_uncollectible,
      provider,
      tenant,
      & &1.mark_invoice_uncollectible(invoice_id, &2)
    )
  end

  @doc "Deletes draft bill `invoice_id`; an open one cannot be deleted, only voided."
  @spec delete_invoice(String.t(), String.t(), term()) :: :ok | {:error, Splode.Error.t()}
  def delete_invoice(provider, invoice_id, tenant \\ nil) when is_binary(invoice_id),
    do: invoice_call(:invoice_delete, provider, tenant, & &1.delete_invoice(invoice_id, &2))

  defp invoice_call(operation, provider, tenant, call) when is_binary(provider),
    do: capable(:invoice, operation, provider, tenant, call)

  @doc """
  Adds a charge for a customer from `attrs` (see `MishkaPay.Invoice.Item`): a catalog
  `:price_id`, or a `:name` and `:amount`, with a `:quantity`. Without `:invoice_id` it waits and
  goes on the customer's next bill (a renewal or a one-off bill); with it, on that draft bill.

      MishkaPay.create_invoice_item(%{provider: "stripe", tenant: site_id, customer_id: id,
                                      name: "Setup fee", amount: %{amount: "49", currency: "USD"},
                                      reference: "setup-" <> account.id})
  """
  @spec create_invoice_item(map()) ::
          {:ok, MishkaPay.Invoice.Item.t()} | {:error, Splode.Error.t()}
  def create_invoice_item(attrs) when is_map(attrs) do
    needed = [:provider, :customer_id]

    made(
      :invoice_item_create,
      :invoice_item,
      attrs,
      MishkaPay.Invoice.Item,
      needed,
      :create_invoice_item
    )
  end

  @doc """
  Changes invoice item `attrs.id` at `attrs.provider`: only the fields given (`:name`,
  `:amount`, `:quantity`, `:price_id`, the tax fields, `:metadata`). Its customer and bill stay:
  `:customer_id` or `:invoice_id` here is refused.
  """
  @spec update_invoice_item(map()) ::
          {:ok, MishkaPay.Invoice.Item.t()} | {:error, Splode.Error.t()}
  def update_invoice_item(%{} = attrs) do
    in_place(attrs, [:customer_id, :invoice_id], :invoice_item_moves, fn ->
      made(
        :invoice_item_update,
        :invoice_item,
        attrs,
        MishkaPay.Invoice.Item,
        [:provider],
        :update_invoice_item
      )
    end)
  end

  # A change of the object `attrs.id` names, refused when it would move the object to another
  # of `fixed` (its customer, its bill).
  defp in_place(attrs, fixed, message, change) do
    case {field(attrs, :id), Enum.find(fixed, &field(attrs, &1))} do
      {nil, _moved} ->
        MishkaPay.ProviderKit.invalid(:id, Messages.text(:customer_needs, field: :id))

      {_id, nil} ->
        change.()

      {_id, moved} ->
        MishkaPay.ProviderKit.invalid(moved, Messages.text(message))
    end
  end

  @doc "Removes invoice item `invoice_item_id`; one on a finalized bill cannot go."
  @spec delete_invoice_item(String.t(), String.t(), term()) :: :ok | {:error, Splode.Error.t()}
  def delete_invoice_item(provider, invoice_item_id, tenant \\ nil)
      when is_binary(provider) and is_binary(invoice_item_id) do
    capable(
      :invoice_item,
      :invoice_item_delete,
      provider,
      tenant,
      & &1.delete_invoice_item(invoice_item_id, &2)
    )
  end

  @doc """
  One page of invoice items at `provider`, newest first (`MishkaPay.Page` of
  `MishkaPay.Invoice.Item`): `customer_id:` one customer's, `invoice_id:` those on one bill,
  `pending: true` only those still waiting for a bill, plus `limit:` and `after:`.
  """
  @spec list_invoice_items(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_invoice_items(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(
      :invoice_item,
      :invoice_item_list,
      provider,
      tenant,
      & &1.list_invoice_items(limited(opts), &2)
    )
  end

  @doc """
  Makes a credit note from `attrs` (see `MishkaPay.CreditNote`) on finalized bill
  `:invoice_id`: an `:amount` of it or `:lines`, a `:reason`, and on a paid bill where the money
  goes (`:refund_amount`, `:credit_amount` onto the customer's balance, `:out_of_band_amount`).
  Its `:reference` makes it once. Try it first with `preview_credit_note/1`.

      MishkaPay.create_credit_note(%{provider: "stripe", tenant: site_id, invoice_id: bill.id,
                                     amount: %{amount: "20", currency: "USD"},
                                     refund_amount: %{amount: "20", currency: "USD"},
                                     reason: :order_change, reference: "credit-" <> order.id})
  """
  @spec create_credit_note(map()) ::
          {:ok, MishkaPay.CreditNote.t()} | {:error, Splode.Error.t()}
  def create_credit_note(attrs) when is_map(attrs) do
    made(
      :credit_note_create,
      :credit_note,
      attrs,
      MishkaPay.CreditNote,
      [:provider, :invoice_id],
      :create_credit_note
    )
  end

  @doc """
  The credit note `create_credit_note/1` would make with the same `attrs`, with its amount, tax
  and lines, without making it.
  """
  @spec preview_credit_note(map()) ::
          {:ok, MishkaPay.CreditNote.t()} | {:error, Splode.Error.t()}
  def preview_credit_note(attrs) when is_map(attrs) do
    made(
      :credit_note_preview,
      :credit_note,
      attrs,
      MishkaPay.CreditNote,
      [:provider, :invoice_id],
      :preview_credit_note
    )
  end

  @doc "Reads credit note `credit_note_id` again from `provider`, with `tenant`'s keys."
  @spec fetch_credit_note(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.CreditNote.t()} | {:error, Splode.Error.t()}
  def fetch_credit_note(provider, credit_note_id, tenant \\ nil)
      when is_binary(provider) and is_binary(credit_note_id) do
    capable(
      :credit_note,
      :credit_note,
      provider,
      tenant,
      & &1.fetch_credit_note(credit_note_id, &2)
    )
  end

  @doc """
  Voids credit note `credit_note_id`: it stays on record and credits nothing. A provider may
  void one only while its bill is open (Stripe does).
  """
  @spec void_credit_note(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.CreditNote.t()} | {:error, Splode.Error.t()}
  def void_credit_note(provider, credit_note_id, tenant \\ nil)
      when is_binary(provider) and is_binary(credit_note_id) do
    capable(
      :credit_note,
      :credit_note_void,
      provider,
      tenant,
      & &1.void_credit_note(credit_note_id, &2)
    )
  end

  @doc """
  One page of credit notes at `provider`, newest first (`MishkaPay.Page` of
  `MishkaPay.CreditNote`): `invoice_id:` those on one bill, `customer_id:` one customer's, plus
  `limit:` and `after:`.
  """
  @spec list_credit_notes(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_credit_notes(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(
      :credit_note,
      :credit_note_list,
      provider,
      tenant,
      & &1.list_credit_notes(limited(opts), &2)
    )
  end

  @doc """
  One page of credit note `credit_note_id`'s lines (`MishkaPay.Page` of
  `MishkaPay.CreditNote.Lines`), plus `limit:` and `after:`.
  """
  @spec list_credit_note_lines(String.t(), String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_credit_note_lines(provider, credit_note_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(credit_note_id) do
    capable(
      :credit_note,
      :credit_note_line_list,
      provider,
      tenant,
      & &1.list_credit_note_lines(credit_note_id, limited(opts), &2)
    )
  end

  @doc """
  Calls any path of the provider's own API with the tenant's keys, for what Mishka Pay has no
  typed call for yet, and answers the provider's decoded answer as it is (a map). `attrs` is a
  `MishkaPay.RawRequest`: `:method`, `:path` (from the root, never an address), `:params`, a
  `:reference` that makes a write's idempotency key, and `:options` (`MishkaPay.RawRequest.Options`:
  `:api_version`, `:expand`). It goes through the same retries, idempotency keys and telemetry as
  every typed call, and an error is the same `MishkaPay.Errors` one.

      MishkaPay.request(%{provider: "stripe", tenant: site_id, path: "/v1/tax/settings"})

      MishkaPay.request(%{provider: "stripe", tenant: site_id, method: :post,
                          path: "/v1/customers/\#{id}", params: %{"preferred_locales" => ["de"]},
                          reference: "locale-\#{id}", options: %{expand: ["tax"]}})

  Reach for it only until a typed call exists: the answer is the provider's own shape, which
  changes with its API version.
  """
  @spec request(map()) :: {:ok, map()} | {:error, Splode.Error.t()}
  def request(attrs) when is_map(attrs) do
    made(:raw_request, :raw_request, attrs, MishkaPay.RawRequest, [:provider], :raw_request)
  end

  @doc """
  One page of `provider`'s events for `tenant`, newest first (`MishkaPay.Page`), each a
  `MishkaPay.Event`: `since:` a `DateTime`, `types:` a list of event types, `object_id:` only the
  events about that object (thin events only), plus `limit:` and `after:`. At a provider with two kinds of events, `events:` (`:thin` or `:snapshot`, else the
  tenant's `:events`) picks which are read: Stripe's thin events come from API v2
  (`/v2/core/events`, 20 a page), each the same Event its webhook gives, named as its snapshot
  event (`invoice.paid`), and `types:` takes those names or Stripe's thin ones
  (`v1.invoice.paid`); snapshot events from `/v1/events`.
  """
  @spec list_events(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_events(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:event_list, :event_list, provider, tenant, & &1.list_events(limited(opts), &2))
  end

  @doc """
  Delivers again every event `provider` sent `tenant` since `since:`, to the
  `mishka_pay:webhook:received` listeners (`MishkaPay.Webhook.deliver/1`), oldest first: what a
  site missed while its webhook endpoint was down. Only the events Mishka Pay acts on are
  delivered, when the provider says which: the window is read once, a hundred events a request,
  and the others are left out. `types:` names the events to deliver instead, and asks the
  provider for only those (Stripe takes 20 types a request). A listener keeps each event once, so
  one already taken is not done twice. `events:` reads the thin or the snapshot events, as in
  `list_events/3`: replay the kind the site's webhook takes, so the ids match those it kept.

  Answers how many were delivered and which failed, by event id.
  """
  @spec replay_events(String.t(), term(), keyword()) ::
          {:ok, %{delivered: non_neg_integer(), failed: [{String.t(), term()}]}}
          | {:error, Splode.Error.t()}
  def replay_events(provider, tenant \\ nil, opts) when is_binary(provider) do
    with {:ok, module} <- Provider.capable(provider, :event_list),
         {:ok, events} <- replayed(provider, tenant, opts, handled(module)) do
      events
      |> Enum.reverse()
      |> Enum.map(&{&1.id, MishkaPay.Webhook.deliver(%{&1 | tenant: tenant})})
      |> Enum.reduce(%{delivered: 0, failed: []}, fn
        {_id, :ok}, acc -> %{acc | delivered: acc.delivered + 1}
        {id, {:error, reason}}, acc -> %{acc | failed: [{id, reason} | acc.failed]}
      end)
      |> then(&{:ok, %{&1 | failed: Enum.reverse(&1.failed)}})
    end
  end

  # The events the provider acts on, by their Event type: of both kinds when it has two.
  defp handled(module) do
    case {function_exported?(module, :event_types, 0),
          function_exported?(module, :handled_events, 0)} do
      {true, _snapshot} -> module.event_types()
      {false, true} -> module.handled_events()
      {false, false} -> nil
    end
  end

  # Without `types:` the window is read unfiltered and only the handled events are kept: one
  # request for a quiet window, where asking by type needs one for each chunk of types.
  defp replayed(provider, tenant, opts, handled) when is_map(handled) do
    case Keyword.has_key?(opts, :types) do
      true ->
        all_events(provider, tenant, opts)

      false ->
        with {:ok, events} <- all_events(provider, tenant, opts) do
          {:ok, Enum.filter(events, &is_map_key(handled, &1.type))}
        end
    end
  end

  defp replayed(provider, tenant, opts, nil), do: all_events(provider, tenant, opts)

  # Every page of every chunk of types (a provider takes a few types a call), newest first, each
  # event once.
  defp all_events(provider, tenant, opts) do
    opts
    |> Keyword.get(:types)
    |> chunks()
    |> Enum.reduce_while({:ok, []}, fn types, {:ok, acc} ->
      chunk = opts |> Keyword.put(:types, types) |> Keyword.put(:limit, 100)

      case Page.all(&list_events(provider, tenant, Keyword.merge(chunk, &1))) do
        {:ok, events} -> {:cont, {:ok, acc ++ events}}
        error -> {:halt, error}
      end
    end)
    |> newest_first()
  end

  defp newest_first({:ok, events}) do
    {:ok,
     events
     |> Enum.uniq_by(& &1.id)
     |> Enum.sort_by(& &1.created_at, &(DateTime.compare(&1, &2) != :lt))}
  end

  defp newest_first(error), do: error

  defp chunks(nil), do: [nil]
  defp chunks(types), do: Enum.chunk_every(types, 20)

  @doc "Reads subscription `subscription_id` again from `provider`, with `tenant`'s keys."
  @spec fetch_subscription(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Subscription.t()} | {:error, Splode.Error.t()}
  def fetch_subscription(provider, subscription_id, tenant \\ nil)
      when is_binary(provider) and is_binary(subscription_id) do
    subscription(:subscription, provider, tenant, & &1.fetch_subscription(subscription_id, &2))
  end

  @doc """
  Cancels subscription `subscription_id`. With `at: :period_end` (the default) the buyer keeps
  what they paid for until the period ends, and `resume_subscription/3` can still take it back;
  with `at: :now` it ends at once.
  """
  @spec cancel_subscription(String.t(), String.t(), term(), keyword()) ::
          {:ok, MishkaPay.Subscription.t()} | {:error, Splode.Error.t()}
  def cancel_subscription(provider, subscription_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(subscription_id) do
    case Keyword.get(opts, :at, :period_end) do
      at when at in [:now, :period_end] ->
        subscription(
          :subscription_cancel,
          provider,
          tenant,
          & &1.cancel_subscription(subscription_id, at, &2)
        )

      other ->
        raise ArgumentError,
              "cancel_subscription at: must be :now or :period_end, got #{inspect(other)}"
    end
  end

  @doc "Takes back a cancel set for the period's end, so subscription `subscription_id` goes on."
  @spec resume_subscription(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Subscription.t()} | {:error, Splode.Error.t()}
  def resume_subscription(provider, subscription_id, tenant \\ nil)
      when is_binary(provider) and is_binary(subscription_id) do
    subscription(
      :subscription_resume,
      provider,
      tenant,
      & &1.resume_subscription(subscription_id, &2)
    )
  end

  @doc """
  One page of invoices at `provider`, newest first (`MishkaPay.Page`): `subscription_id:` one
  subscription's, or `customer_id:` one customer's, plus `limit:` and `after:`.
  """
  @spec list_invoices(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_invoices(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    subscription(:invoices, provider, tenant, & &1.list_invoices(limited(opts), &2))
  end

  @doc "Reads invoice `invoice_id` from `provider`, with its lines, bill page and PDF."
  @spec fetch_invoice(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}
  def fetch_invoice(provider, invoice_id, tenant \\ nil)
      when is_binary(provider) and is_binary(invoice_id) do
    subscription(:invoice, provider, tenant, & &1.fetch_invoice(invoice_id, &2))
  end

  @doc """
  Changes a running subscription (see `MishkaPay.Subscription.Change`): a new plan
  (`:price_id`), a new quantity, or both, billed the way `:proration` says. Answers the
  subscription after. Preview it first with `preview_subscription_change/1`.
  """
  @spec change_subscription(map()) ::
          {:ok, MishkaPay.Subscription.t()} | {:error, Splode.Error.t()}
  def change_subscription(attrs) when is_map(attrs) do
    changed(:subscription_change, attrs, :change_subscription)
  end

  @doc """
  The invoice `change_subscription/1` would make with the same `attrs`, with its proration lines,
  without changing anything. When the change prorates and `attrs` has no `:proration_date`, it
  counts from now: give the same `:proration_date` to both calls to bill exactly the preview.
  """
  @spec preview_subscription_change(map()) ::
          {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}
  def preview_subscription_change(attrs) when is_map(attrs) do
    attrs =
      case MishkaPay.Subscription.change_prorates?(attrs) do
        true -> Map.put_new_lazy(attrs, :proration_date, &DateTime.utc_now/0)
        false -> attrs
      end

    changed(:subscription_preview, attrs, :preview_subscription_change)
  end

  @doc """
  Pauses collecting subscription `subscription_id`'s payments; the subscription stays. `behavior:`
  `:void` (the default: its invoices are voided), `:keep_as_draft` or `:mark_uncollectible`;
  `resumes_at:` when collection starts again by itself.
  """
  @spec pause_collection(String.t(), String.t(), term(), keyword()) ::
          {:ok, MishkaPay.Subscription.t()} | {:error, Splode.Error.t()}
  def pause_collection(provider, subscription_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(subscription_id) do
    behavior = Keyword.get(opts, :behavior, :void)

    case behavior in [:void, :keep_as_draft, :mark_uncollectible] do
      true ->
        capable(
          :subscription_change,
          :subscription_pause,
          provider,
          tenant,
          & &1.pause_collection(subscription_id, Keyword.put(opts, :behavior, behavior), &2)
        )

      false ->
        MishkaPay.ProviderKit.invalid(:behavior, Messages.text(:pause_behavior))
    end
  end

  @doc "Collects paused subscription `subscription_id`'s payments again."
  @spec resume_collection(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Subscription.t()} | {:error, Splode.Error.t()}
  def resume_collection(provider, subscription_id, tenant \\ nil)
      when is_binary(provider) and is_binary(subscription_id) do
    capable(
      :subscription_change,
      :subscription_unpause,
      provider,
      tenant,
      & &1.resume_collection(subscription_id, &2)
    )
  end

  @doc """
  One page of subscriptions at `provider`, newest first (`MishkaPay.Page` of
  `MishkaPay.Subscription`): `customer_id:` one customer's, `price_id:` those that charge a price,
  `status:` those in one status (`MishkaPay.Subscription.statuses/0`) or `:all`, plus `limit:`
  and `after:`. Without `status:` a provider may leave ended ones out (Stripe does). The provider
  needs `:subscription_list`.
  """
  @spec list_subscriptions(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_subscriptions(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    listed(:subscription_list, :list_subscriptions, provider, tenant, opts, [:all])
  end

  @doc """
  One page of `provider`'s subscriptions that match every filter given (`MishkaPay.Page`):
  `status:` (`MishkaPay.Subscription.statuses/0`), `reference:` (the caller's own id from the
  checkout), `metadata:` (a map whose pairs must all match), plus `limit:` and `after:`. A
  subscription just made may take a minute to be found. The provider needs `:subscription_list`.
  """
  @spec search_subscriptions(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def search_subscriptions(provider, tenant \\ nil, opts) when is_binary(provider) do
    listed(:subscription_search, :search_subscriptions, provider, tenant, opts, [])
  end

  @doc """
  Makes a subscription schedule from `attrs` (see `MishkaPay.Subscription.Schedule`): from a
  running `:subscription_id`, or for a `:customer_id` with its `:phases`. Its `:reference` makes
  it once. The provider needs `:subscription_schedule`.

      MishkaPay.create_subscription_schedule(%{provider: "stripe", tenant: site_id,
        customer_id: customer.id, end_behavior: :cancel, reference: "member-" <> member.id,
        phases: [%{items: [%{id: intro.id}], iterations: 3, interval: :month},
                 %{items: [%{id: full.id}], iterations: 9, interval: :month}]})
  """
  @spec create_subscription_schedule(map()) ::
          {:ok, MishkaPay.Subscription.Schedule.t()} | {:error, Splode.Error.t()}
  def create_subscription_schedule(attrs) when is_map(attrs) do
    made(
      :subscription_schedule_create,
      :subscription_schedule,
      attrs,
      MishkaPay.Subscription.Schedule,
      [:provider | MishkaPay.Subscription.schedule_needs(attrs)],
      :create_subscription_schedule
    )
  end

  @doc "Reads subscription schedule `schedule_id` again from `provider`, with its phases."
  @spec fetch_subscription_schedule(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Subscription.Schedule.t()} | {:error, Splode.Error.t()}
  def fetch_subscription_schedule(provider, schedule_id, tenant \\ nil)
      when is_binary(provider) and is_binary(schedule_id) do
    capable(
      :subscription_schedule,
      :subscription_schedule,
      provider,
      tenant,
      & &1.fetch_subscription_schedule(schedule_id, &2)
    )
  end

  @doc """
  One page of subscription schedules at `provider`, newest first (`MishkaPay.Page` of
  `MishkaPay.Subscription.Schedule`): `customer_id:` one customer's, `scheduled: true` only those
  not started yet, plus `limit:` and `after:`.
  """
  @spec list_subscription_schedules(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_subscription_schedules(provider, tenant \\ nil, opts \\ [])
      when is_binary(provider) do
    capable(
      :subscription_schedule,
      :subscription_schedule_list,
      provider,
      tenant,
      & &1.list_subscription_schedules(limited(opts), &2)
    )
  end

  @doc """
  Changes subscription schedule `attrs.id` at `attrs.provider`: only what is given. `:phases`
  replaces the phases from the current one on (the current one with the start it has);
  `:end_behavior` and `:proration` (how this change is billed) as on
  `MishkaPay.Subscription.Schedule`. Its customer and subscription stay.
  """
  @spec update_subscription_schedule(map()) ::
          {:ok, MishkaPay.Subscription.Schedule.t()} | {:error, Splode.Error.t()}
  def update_subscription_schedule(%{} = attrs) do
    in_place(attrs, [:customer_id, :subscription_id], :schedule_moves, fn ->
      made(
        :subscription_schedule_update,
        :subscription_schedule,
        attrs,
        MishkaPay.Subscription.Schedule,
        [:provider],
        :update_subscription_schedule
      )
    end)
  end

  @doc """
  Releases subscription schedule `schedule_id`: the schedule ends, and its subscription goes on
  as it is now, without the phases still to come.
  """
  @spec release_subscription_schedule(String.t(), String.t(), term()) ::
          {:ok, MishkaPay.Subscription.Schedule.t()} | {:error, Splode.Error.t()}
  def release_subscription_schedule(provider, schedule_id, tenant \\ nil)
      when is_binary(provider) and is_binary(schedule_id) do
    capable(
      :subscription_schedule,
      :subscription_schedule_release,
      provider,
      tenant,
      & &1.release_subscription_schedule(schedule_id, &2)
    )
  end

  @doc """
  Cancels subscription schedule `schedule_id` and ends its subscription now. `invoice_now: true`
  bills what is not billed yet, `prorate: true` credits the time not used; each left out is the
  provider's default.
  """
  @spec cancel_subscription_schedule(String.t(), String.t(), term(), keyword()) ::
          {:ok, MishkaPay.Subscription.Schedule.t()} | {:error, Splode.Error.t()}
  def cancel_subscription_schedule(provider, schedule_id, tenant \\ nil, opts \\ [])
      when is_binary(provider) and is_binary(schedule_id) do
    capable(
      :subscription_schedule,
      :subscription_schedule_cancel,
      provider,
      tenant,
      & &1.cancel_subscription_schedule(schedule_id, opts, &2)
    )
  end

  # A subscription list or search, after its `status:` is checked against the statuses a
  # subscription has (and the extra ones this call takes).
  defp listed(operation, callback, provider, tenant, opts, extra) do
    capable(:subscription_list, operation, provider, tenant, fn module, keys ->
      statuses = MishkaPay.Subscription.statuses() ++ extra

      case is_nil(opts[:status]) or opts[:status] in statuses do
        true ->
          apply(module, callback, [limited(opts), keys])

        false ->
          MishkaPay.ProviderKit.invalid(
            :status,
            Messages.text(:subscription_status, statuses: Enum.join(statuses, ", "))
          )
      end
    end)
  end

  defp changed(operation, attrs, callback) do
    span(operation, attrs, fn ->
      with {:ok, change} <- Errors.from_builder(MishkaPay.Subscription.Change.builder(attrs)),
           {:ok, module} <- Provider.capable(change.provider, :subscription_change),
           {:ok, keys} <- Credentials.fetch(change.provider, change.tenant) do
        apply(module, callback, [change, keys])
      end
    end)
  end

  defp subscription(operation, provider, tenant, call) do
    span(operation, %{provider: provider, tenant: tenant}, fn ->
      with {:ok, module} <- Provider.capable(provider, :subscription),
           {:ok, keys} <- Credentials.fetch(provider, tenant) do
        call.(module, keys)
      end
    end)
  end

  # Each choice that needs more than `:checkout` asks the provider for its capability: a
  # subscription, an embedded form, a hold on the card, a card saved without a charge, shipping,
  # a sale for a seller of a platform.
  defp mode_capable(%Checkout{provider: provider} = checkout) do
    [
      {checkout.mode == :subscription, :subscription},
      {checkout.ui_mode == :embedded, :embedded_checkout},
      {checkout.capture == :manual, :capture},
      {checkout.mode == :setup, :payment_method},
      {not is_nil(checkout.shipping_countries) or not is_nil(checkout.shipping_rates), :shipping},
      {Enum.any?(
         [:destination, :on_behalf_of, :application_fee, :application_fee_percent],
         &(not is_nil(Map.get(checkout, &1)))
       ), :connect}
    ]
    |> Enum.reduce_while(:ok, fn
      {true, capability}, :ok ->
        case Provider.capable(provider, capability) do
          {:ok, _module} -> {:cont, :ok}
          error -> {:halt, error}
        end

      {false, _capability}, :ok ->
        {:cont, :ok}
    end)
  end

  defp before_checkout(checkout) do
    timeout = Application.get_env(:mishka_pay, :checkout_gate_timeout, 5_000)
    state = %{checkout: checkout, refused: nil}

    case Plugins.call(Events.checkout_before(), state, timeout) do
      {:ok, %{refused: nil, checkout: %Checkout{} = checkout}} -> {:ok, checkout}
      {:ok, %{refused: reason}} when not is_nil(reason) -> refused(reason)
      {:ok, _not_an_answer} -> refused(:invalid_answer)
      {:error, reason} -> refused(reason)
    end
  end

  defp refused(reason),
    do: {:error, Errors.Refused.exception(operation: :checkout, reason: reason)}

  defp span(operation, attrs, fun) do
    meta = %{provider: field(attrs, :provider), tenant: field(attrs, :tenant)}

    :telemetry.span([:mishka_pay, operation], meta, fn ->
      result = fun.()
      {result, Map.put(meta, :outcome, outcome(result))}
    end)
  end

  defp field(attrs, key) do
    keys = Map.new(attrs, fn {name, value} -> {to_string(name), value} end)
    keys[to_string(key)]
  end

  defp outcome({:ok, _answer}), do: :ok
  defp outcome(:ok), do: :ok
  defp outcome({:error, error}), do: error |> Errors.to_class() |> Map.fetch!(:class)
end

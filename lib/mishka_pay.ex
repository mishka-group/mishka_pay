# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay do
  @moduledoc """
  The calls a project makes to take money: open a checkout, read a payment, refund one; for a
  subscription (started by a checkout in `mode: :subscription`) read it, cancel it, take a cancel
  back and list its invoices; keep customers (create, read, update, list) and open their billing
  portal; keep coupons and promotion codes; keep a catalog of products and prices; make payment
  links that sell them; end an open
  checkout; list payments, invoices, customers, coupons, codes, products and prices page by page
  (`MishkaPay.Page`).

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
      `:payment_list`, `:refund`, `:refund_read`, `:refund_list`;
    * subscriptions: `:subscription`, `:subscription_cancel`, `:subscription_resume`,
      `:subscription_change`, `:subscription_preview`, `:subscription_pause`,
      `:subscription_unpause`, `:invoices`, `:invoice`, `:invoice_upcoming`;
    * one-off bills: `:invoice_create`, `:invoice_finalize`, `:invoice_send`, `:invoice_pay`,
      `:invoice_void`, `:invoice_uncollectible`, `:invoice_delete`;
    * customers: `:customer_create`, `:customer_update`, `:customer`, `:customer_list`,
      `:customer_search`, `:portal`, and their tax ids: `:tax_id_create`, `:tax_id_list`,
      `:tax_id_delete`;
    * discounts: `:coupon_create`, `:coupon`, `:coupon_list`, `:coupon_delete`,
      `:promotion_code_create`, `:promotion_code`, `:promotion_code_list`,
      `:promotion_code_update`;
    * the catalog: `:product_create`, `:product`, `:product_update`, `:product_list`,
      `:price_create`, `:price`, `:price_update`, `:price_list`;
    * payment links: `:payment_link_create`, `:payment_link`, `:payment_link_update`,
      `:payment_link_list`;
    * disputes: `:dispute`, `:dispute_list`, `:dispute_update`, `:dispute_accept`;
    * events: `:event_list`.
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
    PromotionCode,
    Provider,
    Refund,
    TaxId
  }

  alias MishkaPay.Helpers.Plugins

  @doc "Opens a checkout from `attrs` (see `MishkaPay.Checkout`) and answers it with the provider's page."
  @spec checkout(map()) :: {:ok, Checkout.t()} | {:error, Splode.Error.t()}
  def checkout(attrs) when is_map(attrs) do
    span(:checkout, attrs, fn ->
      with {:ok, checkout} <- Errors.from_builder(Checkout.builder(attrs)),
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
  buyer's `:email`, `:name`, `:phone`, `:reference`, `:metadata`. Keep its `:id` on the host's
  user to sell to them again.
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

  @doc "Reads customer `customer_id` again from `provider`, with `tenant`'s keys."
  @spec fetch_customer(String.t(), String.t(), term()) ::
          {:ok, Customer.t()} | {:error, Splode.Error.t()}
  def fetch_customer(provider, customer_id, tenant \\ nil)
      when is_binary(provider) and is_binary(customer_id) do
    capable(:customer, :customer, provider, tenant, & &1.fetch_customer(customer_id, &2))
  end

  @doc """
  One page of customers at `provider`, newest first (`MishkaPay.Page`): `email:` only those with
  that email, plus the list options `limit:` and `after:`.
  """
  @spec list_customers(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_customers(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:customer, :customer_list, provider, tenant, & &1.list_customers(limited(opts), &2))
  end

  @doc """
  Adds a business buyer's tax id to customer `customer_id` from `attrs` (see `MishkaPay.TaxId`):
  its `:type`, such as `"eu_vat"`, and its `:value`. The provider prints it on the customer's
  invoices, and checks it against a government register for the kinds it can
  (`:verification`).

      MishkaPay.create_tax_id("stripe", "cus_123", %{type: "eu_vat", value: "DE123456789"}, site_id)
  """
  @spec create_tax_id(String.t(), String.t(), map(), term()) ::
          {:ok, TaxId.t()} | {:error, Splode.Error.t()}
  def create_tax_id(provider, customer_id, attrs, tenant \\ nil)
      when is_binary(provider) and is_binary(customer_id) and is_map(attrs) do
    attrs = %{
      provider: provider,
      tenant: tenant,
      customer_id: customer_id,
      type: field(attrs, :type),
      value: field(attrs, :value)
    }

    made(:tax_id_create, :tax_id, attrs, TaxId, [:type, :value], :create_tax_id)
  end

  @doc """
  One page of customer `customer_id`'s tax ids at `provider` (`MishkaPay.Page` of
  `MishkaPay.TaxId`), with `limit:` and `after:`.
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
  Opens the provider's billing page for one customer (see `MishkaPay.PortalSession`): `:provider`,
  `:tenant`, `:customer_id`, `:return_url`. Redirect the buyer to the answer's `:url`.
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

  @doc "Makes a promotion code from `attrs` (see `MishkaPay.PromotionCode`) at `attrs.provider`."
  @spec create_promotion_code(map()) :: {:ok, PromotionCode.t()} | {:error, Splode.Error.t()}
  def create_promotion_code(attrs) when is_map(attrs) do
    made(
      :promotion_code_create,
      :discount,
      attrs,
      PromotionCode,
      [:provider, :coupon_id],
      :create_promotion_code
    )
  end

  @doc "Reads promotion code `promotion_code_id` again from `provider`, with `tenant`'s keys."
  @spec fetch_promotion_code(String.t(), String.t(), term()) ::
          {:ok, PromotionCode.t()} | {:error, Splode.Error.t()}
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
  @spec update_promotion_code(map()) :: {:ok, PromotionCode.t()} | {:error, Splode.Error.t()}
  def update_promotion_code(attrs) when is_map(attrs) do
    made(
      :promotion_code_update,
      :discount,
      attrs,
      PromotionCode,
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
  Answers a dispute with evidence (see `MishkaPay.DisputeEvidence`): kept to add more, or sent to
  the bank with `submit: true`. Answers the dispute after.
  """
  @spec update_dispute(map()) :: {:ok, MishkaPay.Dispute.t()} | {:error, Splode.Error.t()}
  def update_dispute(attrs) when is_map(attrs) do
    span(:dispute_update, attrs, fn ->
      with {:ok, evidence} <- Errors.from_builder(MishkaPay.DisputeEvidence.builder(attrs)),
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
  `after:`. A customer just made may take a minute to be found.
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
  Makes a draft bill for a customer from `attrs` (see `MishkaPay.InvoiceDraft`), with its items,
  and answers it as a `MishkaPay.Invoice`. Open it with `finalize_invoice/3`.
  """
  @spec create_invoice(map()) :: {:ok, MishkaPay.Invoice.t()} | {:error, Splode.Error.t()}
  def create_invoice(attrs) when is_map(attrs) do
    span(:invoice_create, attrs, fn ->
      with {:ok, draft} <- Errors.from_builder(MishkaPay.InvoiceDraft.builder(attrs)),
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
  One page of `provider`'s events for `tenant`, newest first (`MishkaPay.Page`), each a
  `MishkaPay.Event`: `since:` a `DateTime`, `types:` a list of event types, plus `limit:` and
  `after:`.
  """
  @spec list_events(String.t(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, Splode.Error.t()}
  def list_events(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    capable(:event_list, :event_list, provider, tenant, & &1.list_events(limited(opts), &2))
  end

  @doc """
  Delivers again every event `provider` sent `tenant` since `since:`, to the
  `mishka_pay:webhook:received` listeners (`MishkaPay.Webhook.deliver/1`), oldest first: what a
  site missed while its webhook endpoint was down. Only the events the provider handles
  (`types:`, by default every event Mishka Pay acts on, when the provider says which) are read.
  A listener keeps each event once, so one already taken is not done twice.

  Answers how many were delivered and which failed, by event id.
  """
  @spec replay_events(String.t(), term(), keyword()) ::
          {:ok, %{delivered: non_neg_integer(), failed: [{String.t(), term()}]}}
          | {:error, Splode.Error.t()}
  def replay_events(provider, tenant \\ nil, opts) when is_binary(provider) do
    with {:ok, module} <- Provider.capable(provider, :event_list),
         opts = Keyword.put_new_lazy(opts, :types, fn -> handled(module) end),
         {:ok, events} <- all_events(provider, tenant, opts) do
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

  defp handled(module) do
    case function_exported?(module, :handled_events, 0) do
      true -> module.handled_events() |> Map.keys() |> Enum.sort()
      false -> nil
    end
  end

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
  Changes a running subscription (see `MishkaPay.SubscriptionChange`): a new plan
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
      case MishkaPay.SubscriptionChange.prorates?(attrs) do
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

  defp changed(operation, attrs, callback) do
    span(operation, attrs, fn ->
      with {:ok, change} <- Errors.from_builder(MishkaPay.SubscriptionChange.builder(attrs)),
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

  # A subscription checkout needs a provider that runs subscriptions.
  defp mode_capable(%Checkout{mode: :subscription, provider: provider}) do
    with {:ok, _module} <- Provider.capable(provider, :subscription), do: :ok
  end

  defp mode_capable(_one_time), do: :ok

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

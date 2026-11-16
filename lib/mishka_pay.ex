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

  Each call is a span, `[:mishka_pay, operation, :start | :stop]`, the operation being
  `:checkout`, `:checkout_read`, `:payment`, `:refund`, `:subscription`, `:subscription_cancel`,
  `:subscription_resume`, `:invoices`, `:customer_create`, `:customer_update`, `:customer`,
  `:customer_list`, `:portal`, `:checkout_expire`, `:coupon_create`, `:coupon`, `:coupon_list`,
  `:coupon_delete`, `:promotion_code_create`, `:promotion_code`, `:promotion_code_list` or
  `:promotion_code_update`, `:payment_list`, `:invoices`, `:product_create`, `:product`,
  `:product_update`, `:product_list`, `:price_create`, `:price`, `:price_update`, `:price_list`, `:payment_link_create`, `:payment_link`, `:payment_link_update`
  or `:payment_link_list`,
  with
  `:provider` and `:tenant`, and on `:stop` the `:outcome`: `:ok` or the error's class (`:invalid`,
  `:provider`, `:unknown`). Never a key or a buyer's details.
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
    Refund
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

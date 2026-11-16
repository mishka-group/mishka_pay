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
      on the subscription.
    * `create_customer/2`, `fetch_customer/2`, `update_customer/2`, `list_customers/2` keep
      Customers (`cus_...`), with the reference in their metadata; `portal_session/2` opens a
      billing portal session for one. Stripe answers a portal session only once the account's
      portal is set up (Settings, Billing, Customer portal), in test mode too.
    * `refund/2` refunds a PaymentIntent, in full or in part, once or many times as the tenant
      allows (`MishkaPay.Refund`).

    * `verify_webhook/3` checks the `Stripe-Signature` header: an HMAC-SHA256 of
      `"<timestamp>.<raw body>"` with the tenant's `webhook_secret`, compared in constant time
      with every `v1` signature in it, signed within the last five minutes
      (`config :mishka_pay, MishkaPay.Providers.Stripe, webhook_tolerance: seconds`), and from the
      same mode (live or test) as the tenant's keys.

  Stripe answers 402 for a declined card (`MishkaPay.Errors.Declined`, with Stripe's decline code)
  and other errors as `MishkaPay.Errors.Rejected` with its code and status.

  Stripe counts a few currencies differently from ISO 4217 (HUF, TWD, ISK, UGX, MGA); a checkout or
  refund in one of them is refused as `MishkaPay.Errors.Unsupported` rather than charged wrong. It
  takes BHD, JOD, KWD, OMR and TND only with a last decimal of 0, and metadata up to 49 keys of 40
  characters with values of 500; anything past that is an `:invalid` error before any request.

  A refund first reads the payment. A tenant that refunds once is refused a second refund, and a
  part refund in another currency than the payment's, or over what is left, is refused, since
  Stripe counts a refund in the payment's own currency.

  `config :mishka_pay, MishkaPay.Providers.Stripe, base_url: "http://localhost:12111"` points it at
  another address, such as Stripe's own mock server in tests.
  """

  use MishkaPay.Provider,
    id: "stripe",
    label: "Stripe",
    capabilities: [
      :checkout,
      :payment_list,
      :catalog,
      :payment_link,
      :expire,
      :refund,
      :subscription,
      :subscription_change,
      :customer,
      :portal,
      :discount,
      :webhook
    ]

  alias MishkaPay.{
    Checkout,
    Client,
    Coupon,
    Customer,
    Errors,
    Messages,
    Page,
    PaymentLink,
    Price,
    Product,
    PromotionCode,
    ProviderKit,
    Refund
  }

  alias MishkaPay.Providers.Stripe.Mapper

  @version "2026-10-28.endive"
  @base_url "https://api.stripe.com"
  @odd_currencies ~w(HUF TWD ISK UGX MGA)a
  @three_decimal ~w(BHD JOD KWD OMR TND)a

  @doc "The Stripe API version every request is pinned to."
  @spec version() :: String.t()
  def version, do: @version

  @impl MishkaPay.Provider
  def checkout(%Checkout{} = checkout, keys) do
    with :ok <- currencies(checkout.items, :checkout),
         :ok <- metadata(checkout.metadata),
         :ok <- expiry(checkout.expires_at),
         {:ok, session} <-
           request(:post, "/v1/checkout/sessions", Mapper.checkout_params(checkout, keys), keys,
             key: ProviderKit.idempotency_key("checkout", checkout.tenant, checkout.reference)
           ) do
      {:ok, Mapper.checkout(session, checkout)}
    end
  end

  @impl MishkaPay.Provider
  def fetch_checkout(checkout_id, keys) do
    with :ok <- stripe_id(checkout_id, "cs_", :checkout_id),
         {:ok, session} <- request(:get, "/v1/checkout/sessions/#{checkout_id}", [], keys) do
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
    with :ok <- stripe_id(payment_id, "pi_", :payment_id),
         {:ok, intent} <-
           request(
             :get,
             "/v1/payment_intents/#{payment_id}",
             [
               {"expand[]", "latest_charge"},
               {"expand[]", "latest_charge.refunds"},
               {"expand[]", "customer"}
             ],
             keys
           ) do
      Mapper.payment(intent)
    end
  end

  @impl MishkaPay.Provider
  def refund(%Refund{} = refund, keys) do
    with :ok <- stripe_id(refund.payment_id, "pi_", :payment_id),
         :ok <- currencies([refund], :refund),
         {:ok, key} <- ProviderKit.refund_key(refund, keys),
         {:ok, payment} <- fetch_payment(refund.payment_id, keys),
         :ok <- ProviderKit.refundable(refund, payment, keys),
         {:ok, answer} <-
           request(:post, "/v1/refunds", Mapper.refund_params(refund), keys, key: key) do
      Mapper.refund(answer, refund)
    end
  end

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

  @impl MishkaPay.Provider
  def portal_session(%MishkaPay.PortalSession{} = session, keys) do
    with :ok <- stripe_id(session.customer_id, "cus_", :customer_id),
         {:ok, answer} <-
           request(
             :post,
             "/v1/billing_portal/sessions",
             %{
               "customer" => session.customer_id,
               "return_url" => session.return_url,
               "configuration" => session.configuration
             },
             keys
           ) do
      {:ok, %{session | id: answer["id"], url: answer["url"]}}
    end
  end

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
         :ok <- currencies([price], :price),
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
    do: page("/v1/payment_links", [active: opts[:active]], opts, keys, &Mapper.payment_link/1)

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

  defp link_prices(items) do
    case Enum.find(items, &(not stripe_price?(&1.id))) do
      nil -> :ok
      _bad -> stripe_id("not a price", "price_", :items)
    end
  end

  defp stripe_price?(id), do: stripe_id(id, "price_", :items) == :ok

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

  # A filter id is checked only when it is given: by its prefix, or as a plain id with no prefix.
  defp maybe_id(nil, _prefix, _field), do: :ok
  defp maybe_id(id, "", field), do: plain_id(id, field)
  defp maybe_id(id, prefix, field), do: stripe_id(id, prefix, field)

  @impl MishkaPay.Provider
  def verify_webhook(payload, headers, keys) when is_binary(payload) do
    with {:ok, secret} <- webhook_secret(keys),
         {:ok, header} <- signature_header(headers),
         {:ok, timestamp, signatures} <- parse_signature(header),
         :ok <- fresh(timestamp),
         :ok <- signed(payload, timestamp, signatures, secret),
         {:ok, %{} = event} <- decode(payload),
         :ok <- same_mode(event, keys) do
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

  defp webhook_secret(%{webhook_secret: secret}) when is_binary(secret) and secret != "",
    do: {:ok, secret}

  defp webhook_secret(keys),
    do:
      {:error,
       Errors.MissingCredentials.exception(
         provider: "stripe",
         tenant: keys.tenant,
         reason: :no_webhook_secret
       )}

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

  defp signed(payload, timestamp, signatures, secret) do
    expected = signature(payload, timestamp, secret)

    case Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected)) do
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

  defp bad(reason),
    do: {:error, Errors.BadSignature.exception(provider: "stripe", reason: reason)}

  # Public for the Stripe-only helpers beside this adapter (`MishkaPay.Providers.Stripe.TestClock`).
  @doc false
  def request(method, path, params, keys, opts \\ []) do
    base = %{
      provider: "stripe",
      method: method,
      base_url: base_url(),
      path: path,
      auth: {:bearer, keys.secret_key},
      headers: %{"stripe-version" => @version},
      idempotency_header: "idempotency-key",
      idempotency_key: opts[:key]
    }

    base
    |> Map.put(body_key(method), form(params))
    |> Client.request()
    |> answer()
  end

  defp body_key(:get), do: :params
  defp body_key(_write), do: :form

  defp answer({:ok, %Req.Response{status: status, body: %{} = body}}) when status in 200..299,
    do: {:ok, body}

  defp answer({:ok, %Req.Response{status: 402, body: %{"error" => error}}}) do
    {:error,
     Errors.Declined.exception(
       provider: "stripe",
       reason: error["decline_code"] || error["code"],
       answer: error
     )}
  end

  defp answer({:ok, %Req.Response{status: status, body: body}}) do
    error = error_of(body)

    {:error,
     Errors.Rejected.exception(
       provider: "stripe",
       status: status,
       code: code_of(error),
       message: error["message"]
     )}
  end

  defp answer({:error, _unreachable} = error), do: error

  defp error_of(%{"error" => %{} = error}), do: error
  defp error_of(_other), do: %{}

  # Stripe gives a reused idempotency key a type and no code, and a code or id already taken only
  # its words.
  defp code_of(%{"type" => "idempotency_error"}), do: "idempotency_error"

  defp code_of(%{"code" => code}) when is_binary(code), do: code

  defp code_of(%{"message" => message}) when is_binary(message) do
    case String.contains?(message, "already exists") do
      true -> "already_exists"
      false -> nil
    end
  end

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
  defp money_off(money), do: currencies([%{amount: money}], :discount)

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

  # Stripe keeps up to 50 metadata keys (one is the reference), of 40 characters, with values of
  # 500.
  defp metadata(nil), do: :ok

  defp metadata(metadata) do
    case map_size(metadata) < 50 and
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

  defp currencies(items, operation) do
    odd =
      for %{amount: %Money{currency: currency}} <- items,
          currency in @odd_currencies,
          uniq: true,
          do: currency

    case odd do
      [] ->
        three_decimal(items)

      [currency | _] ->
        {:error,
         Errors.Unsupported.exception(
           provider: "stripe",
           operation: "#{operation} in #{currency}"
         )}
    end
  end

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

  defp base_url do
    :mishka_pay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:base_url, @base_url)
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

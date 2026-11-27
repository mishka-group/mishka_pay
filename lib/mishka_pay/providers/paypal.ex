# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.PayPal do
  @moduledoc """
  PayPal as a provider: one-time payments with PayPal Orders (v2), subscriptions with billing
  plans, reading a payment, refunds and webhooks. A mishka_installer plugin: supervise it to install it.

      children = [MishkaPay.Providers.PayPal]

  ## Keys

  A site's `MishkaPay.Credentials` for `"paypal"`:

    * `:publishable_key`: the app's client id; `:secret_key`: its secret. Mishka Pay gets an OAuth
      token with them and keeps it until shortly before it expires
      (`MishkaPay.Helpers.TokenCache`).
    * `:webhook_secret`: the id of the webhook in the PayPal app (`WH-...`): PayPal checks each
      message's signature itself, given that id.
    * `:mode`: `:test` talks to PayPal's sandbox, `:live` to PayPal.

  ## How a payment goes

    * `checkout/2` creates an Order (`intent: CAPTURE`) with the items and totals, the return and
      cancel URLs, and the reference (with the checkout's owner, when it names one) as its
      `custom_id`; the idempotency key (`PayPal-Request-Id`)
      comes from the reference. The buyer approves it on PayPal's page and comes back to the return
      URL with the Order id in its `token` parameter.
    * PayPal takes the money only when an approved Order is captured. `fetch_checkout/2` and
      `fetch_payment/2` capture an approved Order before they answer, with a key from the Order, so
      the return page, a webhook and a sync may all ask and it is captured once.
    * The payment's id is the Order's id. `refund/2` refunds its capture, in full or in part, as
      often as the site's refund rule allows (`MishkaPay.ProviderKit`).
    * A checkout in `mode: :subscription` sells one recurring price: it makes a catalog product
      and a billing plan for it (the price every interval, after a free trial of `:trial_days`),
      then the subscription, with idempotency keys from the price and the reference. The buyer
      approves it on PayPal's page and comes back to the return URL with its id (`I-...`) in
      `subscription_id`; that id is also the checkout's id.
    * A subscription's bills are its transactions (`list_invoices/2` by `:subscription_id`), and
      its next bill is the plan's price on its next billing time. PayPal cancels a subscription at
      once (`at: :now`): a cancel at the period's end, taking one back, a customer's bills and one
      bill by id are refused.
    * `raw_request/2` calls any path of PayPal's REST API with the site's OAuth token, a write's
      body as JSON and its reference (with the method and path) as `PayPal-Request-Id`, and
      answers PayPal's JSON as it is (`{}` for an empty answer). PayPal has no API version or
      expand option: either one is refused before any request.
    * `verify_webhook/3` asks PayPal to check the message (`verify-webhook-signature`) and answers
      it as a `MishkaPay.Event` naming its Order, or its subscription (a renewal's sale names it as
      its billing agreement); a refund's and a dispute's name the Order their capture belongs to,
      read once. Before PayPal is asked, a message whose `paypal-transmission-time` is more than
      `:webhook_tolerance` seconds (300) from now is refused as `:too_old`, and one whose
      `paypal-cert-url` is not on `api.paypal.com` or `api.sandbox.paypal.com` as `:certificate`.
    * A payment is `:disputed` while a buyer's dispute holds its capture (one not resolved, or
      resolved for the buyer: `fetch_payment/2` reads the capture's disputes, and a resolved one's
      outcome) and once PayPal reversed the capture.
      `handled_events/0` are the events Mishka Pay acts on, and
      `MishkaPay.Providers.PayPal.WebhookEndpoint` makes a site's webhook with them.
    * `return_checkout_id/1` reads the Order's id (`token`) or the subscription's
      (`subscription_id`) from the return page's query; a return URL made for Stripe goes to
      PayPal without its `{CHECKOUT_SESSION_ID}` placeholder.

  ## What it refuses before any request

  A currency PayPal does not take, an amount with decimals in a currency PayPal takes whole (HUF,
  JPY, TWD), a price by a provider id (PayPal has no stored prices on this path), a subscription
  checkout with more than one price, and a checkout that asks PayPal to sell as the merchant of
  record. Metadata has no
  place on a PayPal Order and is left out.

  ## Errors

  A refused card is `MishkaPay.Errors.Declined`, anything else PayPal refuses
  `MishkaPay.Errors.Rejected`. Both keep PayPal's debug id (the `PayPal-Debug-Id` header) as
  `:request_id` and the error's `information_link` as `:doc_url`, for PayPal's support and the
  log; their messages never show them.

  `config :mishka_pay, MishkaPay.Providers.PayPal, base_url: "http://localhost:..."` points it at
  another address, such as a test server, and `webhook_tolerance: 300` is how many seconds a
  webhook's transmission time may be from now.

  Tested against a stand-in that answers in PayPal's shapes, and against PayPal's own sandbox
  (`mix test --only paypal_live`).
  """

  use MishkaPay.Provider,
    id: "paypal",
    label: "PayPal",
    capabilities: [:checkout, :refund, :subscription, :webhook, :raw_request]

  alias MishkaPay.{Checkout, Client, Errors, Messages, Page, Price, ProviderKit, Refund}
  alias MishkaPay.Helpers.TokenCache
  alias MishkaPay.Providers.PayPal.Mapper

  @sandbox "https://api-m.sandbox.paypal.com"
  @live "https://api-m.paypal.com"

  @currencies ~w(AUD BRL CAD CNY CZK DKK EUR HKD HUF ILS JPY MYR MXN TWD NZD NOK PHP PLN GBP SGD SEK CHF THB USD)a
  @whole ~w(HUF JPY TWD)a

  @signature_headers ~w(paypal-auth-algo paypal-cert-url paypal-transmission-id paypal-transmission-sig paypal-transmission-time)

  @impl MishkaPay.Provider
  def checkout(%Checkout{mode: :subscription} = checkout, keys) do
    with :ok <- no_merchant(checkout),
         :ok <- custom_id_fits(checkout),
         :ok <- no_options(checkout),
         :ok <- named_prices(checkout.items),
         :ok <- currencies(checkout.items, :checkout),
         {:ok, price} <- one_plan(checkout.items),
         {:ok, product} <-
           request(:post, "/v1/catalogs/products", Mapper.product_params(price), keys,
             key: ProviderKit.idempotency_key("product", checkout.tenant, price.name)
           ),
         plan_params = Mapper.plan_params(product["id"], price, checkout),
         {:ok, plan} <-
           request(:post, "/v1/billing/plans", plan_params, keys,
             key: ProviderKit.idempotency_key("plan", checkout.tenant, plan_params)
           ),
         {:ok, sub} <-
           request(
             :post,
             "/v1/billing/subscriptions",
             Mapper.subscription_params(plan["id"], price, checkout),
             keys,
             key: ProviderKit.idempotency_key("subscription", checkout.tenant, checkout.reference)
           ) do
      {:ok, Mapper.subscription_checkout(sub, checkout)}
    end
  end

  def checkout(%Checkout{} = checkout, keys) do
    with :ok <- no_merchant(checkout),
         :ok <- custom_id_fits(checkout),
         :ok <- no_options(checkout),
         :ok <- named_prices(checkout.items),
         :ok <- currencies(checkout.items, :checkout),
         params = Mapper.order_params(checkout),
         {:ok, order} <-
           request(:post, "/v2/checkout/orders", params, keys,
             key: ProviderKit.request_key("checkout", checkout.tenant, checkout.reference, params)
           ) do
      {:ok, Mapper.checkout(order, checkout)}
    end
  end

  # A subscription's checkout is the subscription itself (`I-...`); any other is an Order.
  @impl MishkaPay.Provider
  def fetch_checkout("I-" <> _rest = subscription_id, keys) do
    with :ok <- subscription_id(subscription_id, :checkout_id),
         {:ok, sub} <-
           :get
           |> request("/v1/billing/subscriptions/#{subscription_id}", %{}, keys)
           |> unknown_id() do
      {:ok, Mapper.subscription_checkout(sub)}
    end
  end

  def fetch_checkout(order_id, keys) do
    with :ok <- order_id(order_id, :checkout_id),
         {:ok, order} <- current_order(order_id, keys) do
      {:ok, Mapper.checkout(order)}
    end
  end

  @impl MishkaPay.Provider
  def fetch_subscription(subscription_id, keys) do
    with {:ok, sub} <- read_subscription(subscription_id, keys) do
      Mapper.subscription(sub)
    end
  end

  # PayPal ends a subscription at once: it has no cancel at the period's end to set or take back.
  # One the buyer never approved cannot be canceled (PayPal answers that it is not found); it ends
  # by itself, and the error says so.
  @impl MishkaPay.Provider
  def cancel_subscription(subscription_id, :now, keys) do
    with :ok <- subscription_id(subscription_id, :subscription_id),
         {:ok, _no_content} <- cancel_request(subscription_id, keys) do
      fetch_subscription(subscription_id, keys)
    end
  end

  def cancel_subscription(_subscription_id, :period_end, _keys),
    do: unsupported("canceling a subscription at the period's end (cancel it now)")

  @impl MishkaPay.Provider
  def resume_subscription(_subscription_id, _keys),
    do: unsupported("taking back a cancel at the period's end")

  # A subscription's bills are its transactions, from when it was made until now; one not approved
  # yet has none.
  @impl MishkaPay.Provider
  def list_invoices(opts, keys) do
    case opts[:subscription_id] do
      id when is_binary(id) -> transactions(id, opts[:limit], keys)
      _by_customer -> unsupported("listing a customer's bills")
    end
  end

  @impl MishkaPay.Provider
  def fetch_invoice(_invoice_id, _keys),
    do: unsupported("reading one subscription bill by its id")

  @impl MishkaPay.Provider
  def upcoming_invoice(subscription_id, keys) do
    with {:ok, sub} <- read_subscription(subscription_id, keys) do
      case Mapper.upcoming_invoice(sub) do
        nil ->
          ProviderKit.invalid(
            :subscription_id,
            Messages.text(:no_upcoming_invoice, id: subscription_id)
          )

        answer ->
          answer
      end
    end
  end

  # A subscription comes back with its id in `subscription_id` (its `token` is not the
  # subscription); a payment with the Order's id in `token`.
  @impl MishkaPay.Provider
  def return_checkout_id(%{"subscription_id" => "I-" <> _ = id}),
    do: with(:ok <- subscription_id(id, :checkout_id), do: {:ok, id})

  def return_checkout_id(%{"token" => id}) when is_binary(id),
    do: with(:ok <- order_id(id, :checkout_id), do: {:ok, id})

  def return_checkout_id(_params),
    do: ProviderKit.invalid(:checkout_id, Messages.text(:return_no_checkout))

  @impl MishkaPay.Provider
  def fetch_payment(order_id, keys) do
    with :ok <- order_id(order_id, :payment_id),
         {:ok, order} <- current_order(order_id, keys),
         {:ok, disputed?} <- disputed?(order, keys) do
      Mapper.payment(order, disputed?)
    end
  end

  # Whether a buyer's dispute holds the Order's capture (`GET /v1/customer/disputes` by the
  # capture's id): one that is not resolved, or one resolved for the buyer. A dispute PayPal settled
  # for the seller (`dispute_outcome.outcome_code`) no longer counts; the outcome is on the dispute
  # itself, so each resolved one is read once. An Order with no capture asks nothing.
  defp disputed?(order, keys) do
    case Mapper.capture(order) do
      %{"id" => capture_id} when is_binary(capture_id) ->
        with {:ok, %{} = list} <-
               request(
                 :get,
                 "/v1/customer/disputes",
                 %{"disputed_transaction_id" => capture_id},
                 keys
               ) do
          list |> Map.get("items", []) |> List.wrap() |> open_dispute?(keys)
        end

      _not_captured ->
        {:ok, false}
    end
  end

  defp open_dispute?([], _keys), do: {:ok, false}

  defp open_dispute?([%{"status" => "RESOLVED", "dispute_id" => id} | rest], keys)
       when is_binary(id) do
    with :ok <- dispute_id(id),
         {:ok, dispute} <- request(:get, "/v1/customer/disputes/#{id}", %{}, keys) do
      case Mapper.settled_for_seller?(dispute) do
        true -> open_dispute?(rest, keys)
        false -> {:ok, true}
      end
    end
  end

  defp open_dispute?([_open | _rest], _keys), do: {:ok, true}

  @impl MishkaPay.Provider
  def refund(%Refund{} = refund, keys) do
    with :ok <- order_id(refund.payment_id, :payment_id),
         :ok <- currencies([refund], :refund),
         {:ok, key} <- ProviderKit.refund_key(refund, keys),
         {:ok, order} <- current_order(refund.payment_id, keys),
         {:ok, payment} <- Mapper.payment(order),
         :ok <- ProviderKit.refundable(refund, payment, keys),
         {:ok, capture_id} <- capture_of(order),
         {:ok, answer} <-
           request(
             :post,
             "/v2/payments/captures/#{capture_id}/refund",
             Mapper.refund_params(refund),
             keys,
             key: key
           ) do
      Mapper.refund(answer, refund)
    end
  end

  # PayPal names no API version in a header and expands nothing: such an option is refused.
  @impl MishkaPay.Provider
  def raw_request(%MishkaPay.RawRequest{options: %{api_version: version, expand: expand}}, _keys)
      when not is_nil(version) or not is_nil(expand),
      do: ProviderKit.invalid(:options, Messages.text(:request_options_none, provider: "PayPal"))

  def raw_request(%MishkaPay.RawRequest{} = call, keys) do
    request(call.method, call.path, Map.new(call.params || %{}), keys,
      key: MishkaPay.RawRequest.idempotency_key(call)
    )
  end

  @impl MishkaPay.Provider
  def verify_webhook(payload, headers, keys) when is_binary(payload) do
    with {:ok, webhook_id} <- webhook_id(keys),
         {:ok, event} <- decode(payload),
         {:ok, signature} <- signature(headers),
         :ok <- fresh(signature["transmission_time"]),
         :ok <- paypal_cert(signature["cert_url"]),
         {:ok, %{"verification_status" => "SUCCESS"}} <-
           request(
             :post,
             "/v1/notifications/verify-webhook-signature",
             {:json_text, verification(signature, webhook_id, payload)},
             keys
           ) do
      with {:ok, checked} <- Mapper.event(event, keys.mode == :live),
           do: capture_order(checked, event["resource"], keys)
    else
      {:ok, _not_verified} -> bad_signature(:mismatch)
      {:error, %Errors.BadSignature{}} = error -> error
      {:error, _other} -> bad_signature(:mismatch)
    end
  end

  # A refund's event names only its capture (its `up` link), and a buyer's dispute the capture it
  # holds (`disputed_transactions[].seller_transaction_id`): the capture names the Order, the payment
  # Mishka Pay keeps, in one read. A read PayPal refuses answers 400, so it sends again.
  defp capture_order(%MishkaPay.Event{payment_id: nil} = event, resource, keys) do
    with {:ok, capture_id} <- held_capture(event.object_type, resource),
         {:ok, capture} <- request(:get, "/v2/payments/captures/#{capture_id}", %{}, keys) do
      {:ok,
       %{event | payment_id: get_in(capture, ["supplementary_data", "related_ids", "order_id"])}}
    else
      :none -> {:ok, event}
      {:error, _refused} = error -> error
    end
  end

  defp capture_order(event, _resource, _keys), do: {:ok, event}

  defp held_capture("refund", resource), do: refunded_capture(resource)
  defp held_capture("dispute", resource), do: disputed_capture(resource)
  defp held_capture(_other, _resource), do: :none

  defp refunded_capture(%{"links" => links}) when is_list(links) do
    Enum.find_value(links, :none, fn
      %{"rel" => "up", "href" => href} when is_binary(href) ->
        case Regex.run(~r"/v2/payments/captures/([A-Z0-9]{6,40})\z", href) do
          [_href, id] -> {:ok, id}
          nil -> nil
        end

      _other ->
        nil
    end)
  end

  defp refunded_capture(_resource), do: :none

  defp disputed_capture(%{"disputed_transactions" => [_ | _] = transactions}) do
    Enum.find_value(transactions, :none, fn
      %{"seller_transaction_id" => id} when is_binary(id) ->
        if Regex.match?(~r/\A[A-Z0-9]{6,40}\z/, id), do: {:ok, id}

      _other ->
        nil
    end)
  end

  defp disputed_capture(_resource), do: :none

  @handled ~w(
    CHECKOUT.ORDER.APPROVED CHECKOUT.ORDER.COMPLETED
    PAYMENT.CAPTURE.COMPLETED PAYMENT.CAPTURE.PENDING PAYMENT.CAPTURE.DECLINED
    PAYMENT.CAPTURE.REFUNDED PAYMENT.CAPTURE.REVERSED
    PAYMENT.REFUND.PENDING PAYMENT.REFUND.FAILED
    BILLING.SUBSCRIPTION.ACTIVATED BILLING.SUBSCRIPTION.UPDATED BILLING.SUBSCRIPTION.EXPIRED
    BILLING.SUBSCRIPTION.CANCELLED BILLING.SUBSCRIPTION.SUSPENDED
    BILLING.SUBSCRIPTION.PAYMENT.FAILED
    PAYMENT.SALE.COMPLETED PAYMENT.SALE.REFUNDED PAYMENT.SALE.REVERSED
    CUSTOMER.DISPUTE.CREATED CUSTOMER.DISPUTE.UPDATED CUSTOMER.DISPUTE.RESOLVED
  )

  @doc """
  The PayPal webhook events Mishka Pay acts on, which
  `MishkaPay.Providers.PayPal.WebhookEndpoint.ensure/2` subscribes a site's webhook to: an Order
  approved or completed and its capture's changes and refunds (each named by its Order, the
  payment's id), a buyer's dispute opened, changed or resolved (named by the Order of the capture
  it holds), and a subscription's changes and its renewals' sales.
  """
  @spec handled_events() :: [String.t()]
  def handled_events, do: @handled

  # The Order as it is now; an approved one is captured first, once, whoever asks.
  defp current_order(order_id, keys) do
    with {:ok, order} <- request(:get, "/v2/checkout/orders/#{order_id}", %{}, keys) do
      capture(order, keys)
    end
  end

  defp capture(%{"status" => "APPROVED", "id" => id}, keys) do
    request(:post, "/v2/checkout/orders/#{id}/capture", %{}, keys,
      key: ProviderKit.idempotency_key("capture", nil, id)
    )
  end

  defp capture(order, _keys), do: {:ok, order}

  defp capture_of(order) do
    case Mapper.capture(order) do
      %{"id" => id} -> {:ok, id}
      nil -> ProviderKit.invalid(:payment_id, Messages.text(:refund_nothing_left))
    end
  end

  # PayPal keeps 127 characters of the caller's own: the reference and the owner together.
  defp custom_id_fits(checkout) do
    case Mapper.custom_id(checkout) do
      long when is_binary(long) and byte_size(long) > 127 ->
        ProviderKit.invalid(:reference, Messages.text(:paypal_custom_id))

      _fits ->
        :ok
    end
  end

  defp no_merchant(%Checkout{merchant_of_record: true}),
    do: unsupported("checkout as merchant of record")

  defp no_merchant(_checkout), do: :ok

  # A PayPal subscription follows one plan: one recurring price.
  defp one_plan([%Price{interval: interval} = price]) when not is_nil(interval), do: {:ok, price}
  defp one_plan(_items), do: unsupported("subscription checkout with more than one price")

  defp cancel_request(subscription_id, keys) do
    case request(
           :post,
           "/v1/billing/subscriptions/#{subscription_id}/cancel",
           %{"reason" => "Canceled by the site"},
           keys
         ) do
      {:error, %Errors.Rejected{status: 404}} = error ->
        not_approved(subscription_id, error, keys)

      answer ->
        answer
    end
  end

  defp not_approved(subscription_id, error, keys) do
    case read_subscription(subscription_id, keys) do
      {:ok, %{"status" => status}} when status in ["APPROVAL_PENDING", "APPROVED"] ->
        ProviderKit.invalid(:subscription_id, Messages.text(:paypal_not_approved))

      _other ->
        error
    end
  end

  defp read_subscription(subscription_id, keys) do
    with :ok <- subscription_id(subscription_id, :subscription_id) do
      :get
      |> request("/v1/billing/subscriptions/#{subscription_id}", %{"fields" => "plan"}, keys)
      |> unknown_id()
    end
  end

  # PayPal answers an id it never made, read by its path, as a bad parameter: it is one it has not.
  defp unknown_id(
         {:error, %Errors.Rejected{status: 400, code: "INVALID_PARAMETER_SYNTAX"} = error}
       ),
       do: {:error, %{error | code: "resource_missing"}}

  defp unknown_id(answer), do: answer

  defp transactions(subscription_id, limit, keys) do
    with {:ok, sub} <- read_subscription(subscription_id, keys) do
      case sub["status"] in ["APPROVAL_PENDING", "APPROVED"] do
        true -> {:ok, %Page{items: []}}
        false -> transactions_since(sub, limit, keys)
      end
    end
  end

  defp transactions_since(sub, limit, keys) do
    window = %{
      "start_time" => sub["create_time"],
      "end_time" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    with {:ok, answer} <-
           request(:get, "/v1/billing/subscriptions/#{sub["id"]}/transactions", window, keys),
         {:ok, bills} <- bills(answer["transactions"] || [], sub["id"]) do
      newest = Enum.sort_by(bills, & &1.created_at, {:desc, DateTime})
      {:ok, %Page{items: Enum.take(newest, limit || length(newest)), has_more: false}}
    end
  end

  defp bills(transactions, subscription_id) do
    Enum.reduce_while(transactions, {:ok, []}, fn transaction, {:ok, bills} ->
      case Mapper.invoice(transaction, subscription_id) do
        {:ok, bill} -> {:cont, {:ok, [bill | bills]}}
        error -> {:halt, error}
      end
    end)
  end

  # Checkout options this adapter does not send yet are refused, never left out.
  @options [
    discounts: "discounts",
    allow_promotion_codes: "promotion codes",
    automatic_tax: "automatic tax",
    customer_creation: "customer creation",
    locale: "a page language",
    payment_methods: "chosen payment methods",
    expires_at: "an expiry",
    billing_address: "billing address collection",
    tax_id_collection: "tax id collection",
    invoice: "an invoice"
  ]

  defp no_options(checkout) do
    case Enum.find(@options, fn {field, _label} -> set?(Map.get(checkout, field)) end) do
      nil -> no_tax_behavior(checkout.items)
      {_field, label} -> unsupported("checkout with #{label}")
    end
  end

  # A tax behavior says only how a line's own `:tax_percentage` applies; PayPal counts no tax.
  defp no_tax_behavior(items) do
    cond do
      Enum.any?(items, &(not is_nil(&1.tax_behavior) and is_nil(&1.tax_percentage))) ->
        unsupported("checkout with a tax behavior")

      Enum.any?(items, &set?(&1.tax_rate_ids)) ->
        unsupported("checkout with tax rates")

      true ->
        :ok
    end
  end

  defp set?(value), do: value not in [nil, false, []]

  defp named_prices(items) do
    case Enum.any?(items, &is_binary(&1.id)) do
      false -> :ok
      true -> unsupported("checkout by a provider price id")
    end
  end

  defp currencies(items, operation) do
    case Enum.find(items, &unfit_currency?/1) do
      nil -> :ok
      %{amount: %Money{currency: currency}} -> unsupported("#{operation} in #{currency}")
    end
  end

  defp unfit_currency?(%{amount: %Money{currency: currency, amount: amount}}) do
    currency not in @currencies or
      (currency in @whole and not Decimal.equal?(Decimal.round(amount, 0), amount))
  end

  defp unfit_currency?(_no_amount), do: false

  defp unsupported(operation),
    do: {:error, Errors.Unsupported.exception(provider: "paypal", operation: operation)}

  # A PayPal Order id is letters and digits; anything else never reaches a path.
  defp order_id(id, field) do
    case is_binary(id) and Regex.match?(~r/\A[A-Z0-9]{6,40}\z/, id) do
      true -> :ok
      false -> ProviderKit.invalid(field, Messages.text(:paypal_id, field: field))
    end
  end

  # A PayPal subscription id is `I-` and letters and digits; anything else never reaches a path.
  defp subscription_id(id, field) do
    case is_binary(id) and Regex.match?(~r/\AI-[A-Z0-9]{6,40}\z/, id) do
      true -> :ok
      false -> ProviderKit.invalid(field, Messages.text(:paypal_id, field: field))
    end
  end

  # A PayPal dispute id is `PP-` and letters, digits and dashes; anything else never reaches a path.
  defp dispute_id(id) do
    case Regex.match?(~r/\A[A-Z0-9-]{6,60}\z/, id) do
      true -> :ok
      false -> ProviderKit.invalid(:dispute_id, Messages.text(:paypal_id, field: :dispute_id))
    end
  end

  # A message signed more than `:webhook_tolerance` seconds (300) from now is refused before PayPal
  # is asked: an old message sent again, or a clock far off, costs no request.
  defp fresh(time) do
    tolerance =
      :mishka_pay |> Application.get_env(__MODULE__, []) |> Keyword.get(:webhook_tolerance, 300)

    case DateTime.from_iso8601(time) do
      {:ok, sent, _offset} ->
        if abs(DateTime.diff(DateTime.utc_now(), sent)) <= tolerance,
          do: :ok,
          else: bad_signature(:too_old)

      {:error, _not_a_time} ->
        bad_signature(:malformed)
    end
  end

  # PayPal signs with a certificate of its own API hosts; a message naming any other address for
  # it is refused before PayPal is asked.
  defp paypal_cert(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, port: 443}}
      when host in ["api.paypal.com", "api.sandbox.paypal.com"] ->
        :ok

      _elsewhere ->
        bad_signature(:certificate)
    end
  end

  defp webhook_id(%{webhook_secret: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp webhook_id(_keys), do: bad_signature(:no_secret)

  defp decode(payload) do
    case JSON.decode(payload) do
      {:ok, %{} = event} -> {:ok, event}
      _not_an_event -> bad_signature(:malformed)
    end
  end

  defp signature(headers) do
    found = Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)

    case Enum.all?(@signature_headers, &is_binary(found[&1])) do
      true ->
        {:ok,
         %{
           "auth_algo" => found["paypal-auth-algo"],
           "cert_url" => found["paypal-cert-url"],
           "transmission_id" => found["paypal-transmission-id"],
           "transmission_sig" => found["paypal-transmission-sig"],
           "transmission_time" => found["paypal-transmission-time"]
         }}

      false ->
        bad_signature(:missing_header)
    end
  end

  defp bad_signature(reason),
    do: {:error, Errors.BadSignature.exception(provider: "paypal", reason: reason)}

  # Public for the PayPal-only helpers beside this adapter (`MishkaPay.Providers.PayPal.WebhookEndpoint`).
  @doc false
  def request(method, path, body, keys, opts \\ []) do
    with {:ok, token} <- token(keys) do
      method
      |> spec(path, body, keys, token, opts)
      |> Client.request()
      |> answer(keys)
    end
  end

  defp spec(method, path, body, keys, token, opts) do
    %{
      provider: "paypal",
      method: method,
      base_url: base_url(keys),
      path: path,
      auth: {:bearer, token},
      headers: %{"prefer" => "return=representation"},
      idempotency_header: "paypal-request-id",
      idempotency_key: opts[:key]
    }
    |> Map.merge(body_of(method, body))
  end

  defp body_of(:get, params) when map_size(params) == 0, do: %{}
  defp body_of(:get, params), do: %{params: params}
  defp body_of(_write, {:json_text, text}), do: %{json_text: text}
  defp body_of(_write, body), do: %{json: body}

  # PayPal checks a message's signature against the exact bytes it sent, so the event goes back
  # as it came (`payload`, already decoded once as one JSON object), never decoded and encoded
  # again, which would reorder its keys and change the bytes.
  defp verification(signature, webhook_id, payload) do
    head = signature |> Map.put("webhook_id", webhook_id) |> JSON.encode!()
    String.trim_trailing(head, "}") <> ~s(,"webhook_event":) <> payload <> "}"
  end

  # The app's OAuth token for the site's keys, kept until shortly before it expires.
  defp token(keys) do
    TokenCache.get({:paypal, keys.publishable_key, keys.mode}, fn ->
      %{
        provider: "paypal",
        method: :post,
        base_url: base_url(keys),
        path: "/v1/oauth2/token",
        auth: {:basic, "#{keys.publishable_key}:#{keys.secret_key}"},
        form: %{"grant_type" => "client_credentials"},
        idempotency_header: "paypal-request-id"
      }
      |> Client.request()
      |> token_answer()
    end)
  end

  defp token_answer({:ok, %Req.Response{status: 200, body: %{"access_token" => token} = body}}),
    do: {:ok, token, body["expires_in"] || 3_600}

  defp token_answer({:ok, %Req.Response{status: status, body: body} = response}) do
    {:error,
     Errors.Rejected.exception(
       [
         provider: "paypal",
         status: status,
         code: error_field(body, "error"),
         message: error_field(body, "error_description")
       ] ++ support(response)
     )}
  end

  defp token_answer({:error, _unreachable} = error), do: error

  defp answer({:ok, %Req.Response{status: status, body: %{} = body}}, _keys)
       when status in 200..299,
       do: {:ok, body}

  defp answer({:ok, %Req.Response{status: 204}}, _keys), do: {:ok, %{}}

  # A token PayPal no longer takes is dropped, so the next call gets a new one.
  defp answer({:ok, %Req.Response{status: 401} = response}, keys) do
    TokenCache.drop({:paypal, keys.publishable_key, keys.mode})
    rejected(response)
  end

  defp answer(
         {:ok,
          %Req.Response{status: 422, body: %{"details" => [%{"issue" => issue} | _]} = body} =
            response},
         _keys
       )
       when issue in ["INSTRUMENT_DECLINED", "PAYER_CANNOT_PAY", "TRANSACTION_REFUSED"] do
    {:error,
     Errors.Declined.exception(
       [provider: "paypal", reason: issue, answer: body] ++ support(response)
     )}
  end

  defp answer({:ok, %Req.Response{} = response}, _keys), do: rejected(response)
  defp answer({:error, _unreachable} = error, _keys), do: error

  defp rejected(%Req.Response{status: status, body: body} = response) do
    {:error,
     Errors.Rejected.exception(
       [
         provider: "paypal",
         status: status,
         code: code_of(status, body),
         message: error_field(body, "message")
       ] ++ support(response)
     )}
  end

  # PayPal's "not found" is Stripe's `resource_missing`: one code, one plain message.
  defp code_of(404, _body), do: "resource_missing"
  defp code_of(_status, body), do: issue(body) || error_field(body, "name")

  defp issue(%{"details" => [%{"issue" => issue} | _]}), do: issue
  defp issue(_body), do: nil

  # PayPal names every request in its `PayPal-Debug-Id` header (and an error's `debug_id`), which
  # its support asks for, and links an error to its page (`information_link`).
  defp support(%Req.Response{body: body} = response) do
    [
      request_id:
        List.first(Req.Response.get_header(response, "paypal-debug-id")) ||
          error_field(body, "debug_id"),
      doc_url: information_link(body)
    ]
  end

  defp information_link(%{"information_link" => link}) when is_binary(link), do: link

  defp information_link(%{"links" => links}) when is_list(links),
    do: Enum.find_value(links, &(is_map(&1) and &1["rel"] == "information_link" and &1["href"]))

  defp information_link(_body), do: nil

  defp error_field(%{} = body, name), do: body[name]
  defp error_field(_body, _name), do: nil

  defp base_url(keys) do
    :mishka_pay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get_lazy(:base_url, fn -> if keys.mode == :live, do: @live, else: @sandbox end)
  end
end

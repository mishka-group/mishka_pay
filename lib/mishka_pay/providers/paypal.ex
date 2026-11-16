# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.PayPal do
  @moduledoc """
  PayPal as a provider: one-time payments with PayPal Orders (v2), reading a payment, refunds and
  webhooks. A mishka_installer plugin: supervise it to install it.

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
      cancel URLs, and the reference as its `custom_id`; the idempotency key (`PayPal-Request-Id`)
      comes from the reference. The buyer approves it on PayPal's page and comes back to the return
      URL with the Order id in its `token` parameter.
    * PayPal takes the money only when an approved Order is captured. `fetch_checkout/2` and
      `fetch_payment/2` capture an approved Order before they answer, with a key from the Order, so
      the return page, a webhook and a sync may all ask and it is captured once.
    * The payment's id is the Order's id. `refund/2` refunds its capture, in full or in part, as
      often as the site's refund rule allows (`MishkaPay.ProviderKit`).
    * `verify_webhook/3` asks PayPal to check the message (`verify-webhook-signature`) and answers
      it as a `MishkaPay.Event` naming its Order.

  ## What it refuses before any request

  A currency PayPal does not take, an amount with decimals in a currency PayPal takes whole (HUF,
  JPY, TWD), a price by a provider id (PayPal has no stored prices on this path), a subscription
  checkout, and a checkout that asks PayPal to sell as the merchant of record. Metadata has no
  place on a PayPal Order and is left out.

  `config :mishka_pay, MishkaPay.Providers.PayPal, base_url: "http://localhost:..."` points it at
  another address, such as a test server.

  Tested against a stand-in that answers in PayPal's shapes; the run against PayPal's own sandbox
  is still to come (mishka_pay#17).
  """

  use MishkaPay.Provider,
    id: "paypal",
    label: "PayPal",
    capabilities: [:checkout, :refund, :webhook]

  alias MishkaPay.{Checkout, Client, Errors, Messages, ProviderKit, Refund}
  alias MishkaPay.Helpers.TokenCache
  alias MishkaPay.Providers.PayPal.Mapper

  @sandbox "https://api-m.sandbox.paypal.com"
  @live "https://api-m.paypal.com"

  @currencies ~w(AUD BRL CAD CNY CZK DKK EUR HKD HUF ILS JPY MYR MXN TWD NZD NOK PHP PLN GBP SGD SEK CHF THB USD)a
  @whole ~w(HUF JPY TWD)a

  @signature_headers ~w(paypal-auth-algo paypal-cert-url paypal-transmission-id paypal-transmission-sig paypal-transmission-time)

  @impl MishkaPay.Provider
  def checkout(%Checkout{} = checkout, keys) do
    with :ok <- one_time(checkout),
         :ok <- no_options(checkout),
         :ok <- named_prices(checkout.items),
         :ok <- currencies(checkout.items, :checkout),
         {:ok, order} <-
           request(:post, "/v2/checkout/orders", Mapper.order_params(checkout), keys,
             key: ProviderKit.idempotency_key("checkout", checkout.tenant, checkout.reference)
           ) do
      {:ok, Mapper.checkout(order, checkout)}
    end
  end

  @impl MishkaPay.Provider
  def fetch_checkout(order_id, keys) do
    with :ok <- order_id(order_id, :checkout_id),
         {:ok, order} <- current_order(order_id, keys) do
      {:ok, Mapper.checkout(order)}
    end
  end

  @impl MishkaPay.Provider
  def fetch_payment(order_id, keys) do
    with :ok <- order_id(order_id, :payment_id),
         {:ok, order} <- current_order(order_id, keys) do
      Mapper.payment(order)
    end
  end

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

  @impl MishkaPay.Provider
  def verify_webhook(payload, headers, keys) when is_binary(payload) do
    with {:ok, webhook_id} <- webhook_id(keys),
         {:ok, event} <- decode(payload),
         {:ok, signature} <- signature(headers),
         {:ok, %{"verification_status" => "SUCCESS"}} <-
           request(
             :post,
             "/v1/notifications/verify-webhook-signature",
             Map.merge(signature, %{"webhook_id" => webhook_id, "webhook_event" => event}),
             keys
           ) do
      Mapper.event(event, keys.mode == :live)
    else
      {:ok, _not_verified} -> bad_signature(:mismatch)
      {:error, %Errors.BadSignature{}} = error -> error
      {:error, _other} -> bad_signature(:mismatch)
    end
  end

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

  defp one_time(%Checkout{mode: :subscription}), do: unsupported("subscription checkout")

  defp one_time(%Checkout{merchant_of_record: true}),
    do: unsupported("checkout as merchant of record")

  defp one_time(_checkout), do: :ok

  # Checkout options this adapter does not send yet are refused, never left out.
  @options [
    discounts: "discounts",
    allow_promotion_codes: "promotion codes",
    automatic_tax: "automatic tax",
    customer_creation: "customer creation",
    locale: "a page language",
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

  defp no_tax_behavior(items) do
    case Enum.any?(items, &(not is_nil(&1.tax_behavior))) do
      false -> :ok
      true -> unsupported("checkout with a tax behavior")
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

  defp request(method, path, body, keys, opts \\ []) do
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

  defp body_of(:get, _body), do: %{}
  defp body_of(_write, body), do: %{json: body}

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

  defp token_answer({:ok, %Req.Response{status: status, body: body}}) do
    {:error,
     Errors.Rejected.exception(
       provider: "paypal",
       status: status,
       code: error_field(body, "error"),
       message: error_field(body, "error_description")
     )}
  end

  defp token_answer({:error, _unreachable} = error), do: error

  defp answer({:ok, %Req.Response{status: status, body: %{} = body}}, _keys)
       when status in 200..299,
       do: {:ok, body}

  # A token PayPal no longer takes is dropped, so the next call gets a new one.
  defp answer({:ok, %Req.Response{status: 401, body: body}}, keys) do
    TokenCache.drop({:paypal, keys.publishable_key, keys.mode})
    rejected(401, body)
  end

  defp answer(
         {:ok,
          %Req.Response{status: 422, body: %{"details" => [%{"issue" => issue} | _]} = body}},
         _keys
       )
       when issue in ["INSTRUMENT_DECLINED", "PAYER_CANNOT_PAY", "TRANSACTION_REFUSED"] do
    {:error, Errors.Declined.exception(provider: "paypal", reason: issue, answer: body)}
  end

  defp answer({:ok, %Req.Response{status: status, body: body}}, _keys), do: rejected(status, body)
  defp answer({:error, _unreachable} = error, _keys), do: error

  defp rejected(status, body) do
    {:error,
     Errors.Rejected.exception(
       provider: "paypal",
       status: status,
       code: issue(body) || error_field(body, "name"),
       message: error_field(body, "message")
     )}
  end

  defp issue(%{"details" => [%{"issue" => issue} | _]}), do: issue
  defp issue(_body), do: nil

  defp error_field(%{} = body, name), do: body[name]
  defp error_field(_body, _name), do: nil

  defp base_url(keys) do
    :mishka_pay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get_lazy(:base_url, fn -> if keys.mode == :live, do: @live, else: @sandbox end)
  end
end

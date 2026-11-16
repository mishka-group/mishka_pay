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

  Stripe counts a few currencies differently from ISO 4217: ISK and UGX as two-decimal amounts
  ending in 00, and MGA as zero-decimal. Mishka Pay sends and reads them as Stripe counts them,
  and refuses a fraction of one before any request. HUF and TWD charge with two decimals like
  other currencies (Stripe pays them out in whole units). It takes BHD, JOD, KWD, OMR and TND only with a last decimal of 0, and metadata up to 48 keys of 40
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
      :embedded_checkout,
      :capture,
      :payment_list,
      :catalog,
      :payment_link,
      :dispute,
      :expire,
      :refund,
      :refund_read,
      :subscription,
      :subscription_change,
      :invoice,
      :customer,
      :portal,
      :discount,
      :webhook,
      :event_list
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
  @reference "mishka_pay_reference"
  @base_url "https://api.stripe.com"
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
    "invoice.paid" => [:subscription],
    "invoice.payment_failed" => [:subscription],
    "invoice.finalized" => [:subscription],
    "invoice.payment_action_required" => [:subscription],
    "invoice.voided" => [:subscription],
    "invoice.marked_uncollectible" => [:subscription],
    "invoice.overdue" => [:subscription],
    "invoice.upcoming" => [:subscription],
    "invoice_payment.paid" => [:payment],
    "customer.subscription.created" => [:subscription],
    "customer.subscription.updated" => [:subscription],
    "customer.subscription.deleted" => [:subscription],
    "customer.subscription.paused" => [:subscription],
    "customer.subscription.resumed" => [:subscription],
    "customer.subscription.trial_will_end" => [:subscription],
    "customer.created" => [:customer],
    "customer.updated" => [:customer],
    "customer.deleted" => [:customer]
  }

  @doc """
  The Stripe events that change what Mishka Pay keeps, each with what it updates: `:payment`
  (a resource with `mishka_pay do kind :payment end`), `:subscription`, `:customer` or `:dispute`. Each is mapped to its
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
         :ok <- expiry(checkout.expires_at),
         :ok <- held(checkout, keys),
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
             [{"expand[]", "line_items"}],
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
         {:ok, %{"data" => sessions}} <-
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
      {:ok, Mapper.with_checkout(payment, List.first(sessions))}
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

  # Stripe's search language: each filter quoted, a quote inside escaped; the reference is kept
  # in the customer's metadata. Search pages on its own `next_page` cursor.
  @impl MishkaPay.Provider
  def search_customers(opts, keys) do
    clauses =
      for {field, key} <- [email: "email", name: "name", reference: "metadata['#{@reference}']"],
          value = opts[field],
          is_binary(value),
          do: "#{key}:'#{String.replace(value, ~S('), ~S(\'))}'"

    case clauses do
      [] ->
        invalid(:query, Messages.text(:search_needs))

      clauses ->
        params =
          [query: Enum.join(clauses, " AND "), limit: opts[:limit], page: opts[:after]]
          |> Enum.reject(fn {_name, value} -> is_nil(value) end)
          |> Enum.map(fn {name, value} -> {Atom.to_string(name), to_string(value)} end)

        with {:ok, %{"data" => data} = answer} <-
               request(:get, "/v1/customers/search", params, keys),
             {:ok, items} <- data |> Enum.map(&Mapper.customer/1) |> all_ok() do
          next = answer["has_more"] == true && answer["next_page"]
          {:ok, struct(Page, items: items, has_more: is_binary(next), next: next || nil)}
        end
    end
  end

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

  # Stripe's dispute ids start with `du_` now and `dp_` on older disputes.
  defp dispute_id("du_" <> _ = id), do: stripe_id(id, "du_", :dispute_id)
  defp dispute_id(id), do: stripe_id(id, "dp_", :dispute_id)

  # A filter id is checked only when it is given: by its prefix, or as a plain id with no prefix.
  defp maybe_id(nil, _prefix, _field), do: :ok
  defp maybe_id(id, "", field), do: plain_id(id, field)
  defp maybe_id(id, prefix, field), do: stripe_id(id, prefix, field)

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
       param: field_of(error["param"] || param_in(error["message"])),
       message: error["message"]
     )}
  end

  defp answer({:error, _unreachable} = error), do: error

  defp error_of(%{"error" => %{} = error}), do: error
  defp error_of(_other), do: %{}

  # Stripe's names of the fields Mishka Pay calls otherwise; any other is kept as Stripe says it.
  @fields [
    {"subscription_data", "trial_days"},
    {"restrictions", "max_purchases"},
    {"proration_behavior", "proration"},
    {"invoice_creation", "invoice"},
    {"managed_payments", "merchant_of_record"},
    {"after_completion", "success_url"}
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
      String.contains?(message, "product tax code is missing") -> "tax_code"
      String.contains?(message, "separate authorization and capture") -> "capture"
      match = Regex.run(~r/\A`(\w+)` can only be used/, message) -> List.last(match)
      true -> nil
    end
  end

  defp param_in(_no_message), do: nil

  # Stripe gives a reused idempotency key a type and no code, and a code or id already taken only
  # its words; so is an invoice turned off where Managed Payments must make one, a product without
  # the tax code it needs, a choice that belongs only to one-time or only to recurring prices, and
  # a hold on the card where an invoice is made after payment.
  defp code_of(%{"type" => "idempotency_error"}), do: "idempotency_error"

  defp code_of(%{"code" => code}) when is_binary(code), do: code

  defp code_of(%{"message" => message}) when is_binary(message) do
    cond do
      String.contains?(message, "already exists") -> "already_exists"
      String.contains?(message, "when Managed Payments is enabled") -> "managed_payments_invoice"
      String.contains?(message, "product tax code is missing") -> "tax_code_missing"
      String.contains?(message, "does not contain any recurring prices") -> "one_time_only"
      String.contains?(message, "must pass a recurring price") -> "recurring_only"
      String.contains?(message, "separate authorization and capture") -> "capture_invoice"
      true -> nil
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

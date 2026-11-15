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

    * `checkout/2` opens a Checkout Session in `payment` mode and answers its page. The caller's
      `:reference` goes to Stripe as `client_reference_id` and as metadata on the session and its
      payment, and it makes the idempotency key, so the same reference never opens two sessions.
    * `fetch_payment/2` reads a PaymentIntent with its latest charge, which tells refunds apart.
    * `refund/2` refunds a PaymentIntent, in full or in part.

  Stripe answers 402 for a declined card (`MishkaPay.Errors.Declined`, with Stripe's decline code)
  and other errors as `MishkaPay.Errors.Rejected` with its code and status.

  Stripe counts a few currencies differently from ISO 4217 (HUF, TWD, ISK, UGX, MGA); a checkout or
  refund in one of them is refused as `MishkaPay.Errors.Unsupported` rather than charged wrong. It
  takes BHD, JOD, KWD, OMR and TND only with a last decimal of 0, and metadata up to 49 keys of 40
  characters with values of 500; anything past that is an `:invalid` error before any request.

  A part refund first reads the payment, since Stripe counts a refund in the payment's own
  currency: an amount in another currency, or more than is left, is refused. A whole refund sends
  no amount and needs no read.

  `config :mishka_pay, MishkaPay.Providers.Stripe, base_url: "http://localhost:12111"` points it at
  another address, such as Stripe's own mock server in tests.
  """

  use MishkaPay.Provider,
    id: "stripe",
    label: "Stripe",
    capabilities: [:checkout, :refund]

  alias MishkaPay.{Checkout, Client, Errors, Refund}
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
         {:ok, session} <-
           request(:post, "/v1/checkout/sessions", Mapper.checkout_params(checkout), keys,
             key: idempotency_key("checkout", checkout.tenant, checkout.reference)
           ) do
      {:ok, Mapper.checkout(session, checkout)}
    end
  end

  @impl MishkaPay.Provider
  def fetch_payment(payment_id, keys) do
    with :ok <- stripe_id(payment_id),
         {:ok, intent} <-
           request(
             :get,
             "/v1/payment_intents/#{payment_id}",
             [{"expand[]", "latest_charge"}],
             keys
           ) do
      Mapper.payment(intent)
    end
  end

  @impl MishkaPay.Provider
  def refund(%Refund{} = refund, keys) do
    with :ok <- stripe_id(refund.payment_id),
         :ok <- currencies([refund], :refund),
         :ok <- refundable(refund, keys),
         {:ok, answer} <-
           request(:post, "/v1/refunds", Mapper.refund_params(refund), keys,
             key: idempotency_key("refund", refund.tenant, refund.reference)
           ) do
      Mapper.refund(answer, refund)
    end
  end

  defp request(method, path, params, keys, opts \\ []) do
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
       code: error["code"],
       message: error["message"]
     )}
  end

  defp answer({:error, _unreachable} = error), do: error

  defp error_of(%{"error" => %{} = error}), do: error
  defp error_of(_other), do: %{}

  # A Stripe id is letters, digits and underscores; anything else never reaches a path.
  defp stripe_id(id) do
    case is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_]+\z/, id) do
      true ->
        :ok

      false ->
        Errors.from_builder(
          {:error,
           [
             %{
               field: :payment_id,
               action: :stripe_id,
               message: "The payment_id field is not a Stripe id"
             }
           ]}
        )
    end
  end

  # Stripe has no currency on a refund: it counts the amount in the payment's own currency. So a
  # part refund reads the payment first, and refuses another currency or more than is left. A
  # whole refund (no amount) needs no read.
  defp refundable(%Refund{amount: nil}, _keys), do: :ok

  defp refundable(%Refund{amount: amount, payment_id: id}, keys) do
    with {:ok, payment} <- fetch_payment(id, keys) do
      left = Decimal.sub(payment.amount.amount, payment.amount_refunded.amount)

      cond do
        amount.currency != payment.amount.currency ->
          invalid(
            :amount,
            "The amount field must be in the payment's currency, #{payment.amount.currency}"
          )

        Decimal.gt?(amount.amount, left) ->
          invalid(:amount, "The amount field is more than is left to refund on the payment")

        true ->
          :ok
      end
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
          "The metadata field is over Stripe's limits: 49 keys of 40 characters, values of 500"
        )
    end
  end

  defp invalid(field, message),
    do: Errors.from_builder({:error, [%{field: field, action: :stripe, message: message}]})

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
        invalid(:amount, "Stripe takes three-decimal currencies only with a last decimal of 0")
    end
  end

  defp three_decimal_ok?(%{amount: %Money{currency: currency} = money})
       when currency in @three_decimal,
       do: rem(MishkaPay.Money.to_minor(money), 10) == 0

  defp three_decimal_ok?(_item), do: true

  # The same reference for the same tenant is the same request to Stripe, however often it is sent.
  defp idempotency_key(_operation, _tenant, nil), do: nil

  defp idempotency_key(operation, tenant, reference) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({tenant, reference}))
    "mishka_pay-#{operation}-" <> Base.url_encode64(digest, padding: false)
  end

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

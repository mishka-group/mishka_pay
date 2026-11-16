# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.Stripe.Mapper do
  @moduledoc """
  The only place that knows Stripe's field names: Mishka Pay's structs become Stripe's params, and
  Stripe's JSON objects (API version `2026-10-28.endive`) become Mishka Pay's structs.
  """

  alias MishkaPay.{Checkout, Event, Money, Payment, Price, Refund}

  @reference "mishka_pay_reference"

  @checkout_statuses %{"open" => :open, "complete" => :complete, "expired" => :expired}

  @refund_statuses %{
    "pending" => :pending,
    "succeeded" => :succeeded,
    "failed" => :failed,
    "canceled" => :canceled,
    "requires_action" => :requires_action
  }

  @doc "Params of `POST /v1/checkout/sessions` for a checkout in `payment` mode."
  @spec checkout_params(Checkout.t(), map()) :: map()
  def checkout_params(%Checkout{} = checkout, settings \\ %{}) do
    reference = %{@reference => checkout.reference}

    %{
      "mode" => "payment",
      "line_items" => Enum.map(checkout.items, &line_item/1),
      "success_url" => checkout.success_url,
      "cancel_url" => checkout.cancel_url,
      "client_reference_id" => checkout.reference,
      "metadata" => Map.merge(checkout.metadata || %{}, reference),
      "payment_intent_data" => %{"metadata" => reference}
    }
    |> Map.merge(customer(checkout.customer))
    |> Map.merge(managed_payments(merchant_of_record(checkout, settings)))
  end

  # The checkout's own choice, else the tenant's setting, else nil: the Stripe account's default.
  defp merchant_of_record(%Checkout{merchant_of_record: choice}, _settings)
       when is_boolean(choice),
       do: choice

  defp merchant_of_record(_checkout, settings), do: Map.get(settings, :merchant_of_record)

  # Stripe Managed Payments is Stripe selling as the merchant of record; nil leaves the account's
  # own default.
  defp managed_payments(nil), do: %{}
  defp managed_payments(enabled), do: %{"managed_payments" => %{"enabled" => enabled}}

  defp line_item(%Price{id: id, quantity: quantity}) when is_binary(id),
    do: %{"price" => id, "quantity" => quantity}

  defp line_item(%Price{name: name, amount: amount, quantity: quantity, tax_code: tax_code}) do
    %{
      "price_data" => %{
        "currency" => amount.currency |> to_string() |> String.downcase(),
        "unit_amount" => Money.to_minor(amount),
        "product_data" => %{"name" => name, "tax_code" => tax_code}
      },
      "quantity" => quantity
    }
  end

  defp customer(%{id: id}) when is_binary(id), do: %{"customer" => id}
  defp customer(%{email: email}) when is_binary(email), do: %{"customer_email" => email}
  defp customer(_none), do: %{}

  @doc "The checkout with Stripe's answer: its session id, page, status and payment."
  @spec checkout(map(), Checkout.t()) :: Checkout.t()
  def checkout(session, %Checkout{} = checkout) do
    %{
      checkout
      | id: session["id"],
        url: session["url"],
        status: Map.get(@checkout_statuses, session["status"]),
        payment_id: id_of(session["payment_intent"])
    }
  end

  @doc "A PaymentIntent, with its latest charge expanded, as a `MishkaPay.Payment`."
  @spec payment(map()) :: {:ok, Payment.t()} | {:error, Splode.Error.t()}
  def payment(intent) do
    charge = expanded(intent["latest_charge"])

    with {:ok, amount} <- Money.from_minor(intent["amount"], intent["currency"]),
         {:ok, refunded} <- Money.from_minor(charge["amount_refunded"] || 0, intent["currency"]) do
      %{
        provider: "stripe",
        id: intent["id"],
        amount: amount,
        amount_refunded: refunded,
        status: payment_status(intent, refunded, amount),
        reference: get_in(intent, ["metadata", @reference]),
        customer_id: id_of(intent["customer"]),
        created_at: time(intent["created"])
      }
      |> Payment.builder()
      |> MishkaPay.Errors.from_builder()
    end
  end

  defp payment_status(%{"status" => "succeeded"}, refunded, amount) do
    cond do
      Decimal.eq?(refunded.amount, 0) -> :paid
      Decimal.lt?(refunded.amount, amount.amount) -> :partially_refunded
      true -> :refunded
    end
  end

  defp payment_status(%{"status" => "requires_action"}, _refunded, _amount), do: :requires_action
  defp payment_status(%{"status" => "canceled"}, _refunded, _amount), do: :canceled

  defp payment_status(
         %{"status" => "requires_payment_method", "last_payment_error" => %{}},
         _r,
         _a
       ),
       do: :failed

  defp payment_status(_waiting, _refunded, _amount), do: :pending

  @doc "Params of `POST /v1/refunds`: the payment, and the amount when it is not the whole."
  @spec refund_params(Refund.t()) :: map()
  def refund_params(%Refund{} = refund) do
    %{
      "payment_intent" => refund.payment_id,
      "amount" => refund.amount && Money.to_minor(refund.amount),
      "reason" => refund.reason && Atom.to_string(refund.reason),
      "metadata" => refund.reference && %{@reference => refund.reference}
    }
  end

  @doc "The refund with Stripe's answer: its id, status, amount and time."
  @spec refund(map(), Refund.t()) :: {:ok, Refund.t()} | {:error, Splode.Error.t()}
  def refund(answer, %Refund{} = refund) do
    with {:ok, amount} <- Money.from_minor(answer["amount"], answer["currency"]) do
      {:ok,
       %{
         refund
         | id: answer["id"],
           status: Map.get(@refund_statuses, answer["status"]),
           amount: amount,
           created_at: time(answer["created"])
       }}
    end
  end

  @doc "A Stripe event (`object: \"event\"`) as a `MishkaPay.Event`, with what it is about."
  @spec event(map()) :: {:ok, Event.t()} | {:error, Splode.Error.t()}
  def event(event) do
    object = object_of(event)

    %{
      provider: "stripe",
      id: event["id"],
      type: event["type"],
      object_id: object["id"],
      object_type: object["object"],
      payment_id: payment_of(object),
      livemode: event["livemode"],
      account: event["account"],
      created_at: time(event["created"])
    }
    |> Event.builder()
    |> MishkaPay.Errors.from_builder()
  end

  # A PaymentIntent is the payment; a session, charge, refund or dispute points at its own.
  defp payment_of(%{"object" => "payment_intent", "id" => id}) when is_binary(id), do: id
  defp payment_of(%{"payment_intent" => payment}), do: id_of(payment)
  defp payment_of(_other), do: nil

  defp object_of(%{"data" => %{"object" => %{} = object}}), do: object
  defp object_of(_no_object), do: %{}

  defp expanded(%{} = object), do: object
  defp expanded(_id_or_nil), do: %{}

  defp id_of(%{"id" => id}), do: id
  defp id_of(id) when is_binary(id), do: id
  defp id_of(_none), do: nil

  defp time(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, time} -> time
      {:error, _out_of_range} -> nil
    end
  end

  defp time(_none), do: nil
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.Stripe.Mapper do
  @moduledoc """
  The only place that knows Stripe's field names: Mishka Pay's structs become Stripe's params, and
  Stripe's JSON objects (API version `2026-10-28.endive`) become Mishka Pay's structs.
  """

  alias MishkaPay.{Checkout, Event, Invoice, Money, Payment, Price, Refund, Subscription}

  @reference "mishka_pay_reference"

  @checkout_statuses %{"open" => :open, "complete" => :complete, "expired" => :expired}

  @refund_reasons %{
    "requested_by_customer" => :requested_by_customer,
    "duplicate" => :duplicate,
    "fraudulent" => :fraudulent
  }

  @refund_statuses %{
    "pending" => :pending,
    "succeeded" => :succeeded,
    "failed" => :failed,
    "canceled" => :canceled,
    "requires_action" => :requires_action
  }

  @doc """
  Params of `POST /v1/checkout/sessions`: a one-time payment, or a subscription with its trial.
  The reference goes on the payment or the subscription too, so it comes back on either.
  """
  @spec checkout_params(Checkout.t(), map()) :: map()
  def checkout_params(%Checkout{} = checkout, settings \\ %{}) do
    reference = %{@reference => checkout.reference}

    %{
      "mode" => Atom.to_string(checkout.mode),
      "line_items" => Enum.map(checkout.items, &line_item/1),
      "success_url" => checkout.success_url,
      "cancel_url" => checkout.cancel_url,
      "client_reference_id" => checkout.reference,
      "metadata" => Map.merge(checkout.metadata || %{}, reference)
    }
    |> Map.merge(mode_data(checkout, reference))
    |> Map.merge(customer(checkout.customer))
    |> Map.merge(managed_payments(merchant_of_record(checkout, settings)))
  end

  defp mode_data(%Checkout{mode: :subscription, trial_days: days}, reference),
    do: %{
      "subscription_data" => %{"metadata" => reference, "trial_period_days" => days}
    }

  defp mode_data(_payment, reference), do: %{"payment_intent_data" => %{"metadata" => reference}}

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

  defp line_item(
         %Price{name: name, amount: amount, quantity: quantity, tax_code: tax_code} = price
       ) do
    %{
      "price_data" =>
        %{
          "currency" => amount.currency |> to_string() |> String.downcase(),
          "unit_amount" => Money.to_minor(amount),
          "product_data" => %{"name" => name, "tax_code" => tax_code}
        }
        |> Map.merge(recurring(price)),
      "quantity" => quantity
    }
  end

  defp recurring(%Price{interval: nil}), do: %{}

  defp recurring(%Price{interval: interval, interval_count: count}),
    do: %{"recurring" => %{"interval" => Atom.to_string(interval), "interval_count" => count}}

  defp customer(%{id: id}) when is_binary(id), do: %{"customer" => id}
  defp customer(%{email: email}) when is_binary(email), do: %{"customer_email" => email}
  defp customer(_none), do: %{}

  @doc "A Checkout Session read back on its own: what Stripe filled in and the reference."
  @spec checkout(map()) :: Checkout.t()
  def checkout(session) do
    read_back =
      struct(Checkout,
        provider: "stripe",
        items: [],
        reference: session["client_reference_id"],
        customer: buyer(get_in(session, ["customer_details", "email"]))
      )

    checkout(session, read_back)
  end

  @doc "The checkout with Stripe's answer: its session id, page, status and payment."
  @spec checkout(map(), Checkout.t()) :: Checkout.t()
  def checkout(session, %Checkout{} = checkout) do
    %{
      checkout
      | id: session["id"],
        url: session["url"],
        status: Map.get(@checkout_statuses, session["status"]),
        payment_id: id_of(session["payment_intent"]),
        subscription_id: id_of(session["subscription"]),
        amount_total: money(session["amount_total"], session["currency"]),
        amount_tax: money(get_in(session, ["total_details", "amount_tax"]), session["currency"])
    }
  end

  defp buyer(email) when is_binary(email), do: struct(MishkaPay.Customer, email: email)
  defp buyer(_none), do: nil

  defp money(minor, currency) when is_integer(minor) and is_binary(currency) do
    case Money.from_minor(minor, currency) do
      {:ok, money} -> money
      {:error, _odd} -> nil
    end
  end

  defp money(_minor, _currency), do: nil

  @doc """
  A PaymentIntent, with its latest charge, the charge's refunds and the customer expanded, as a
  `MishkaPay.Payment`.
  """
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
        description: intent["description"],
        metadata: Map.delete(intent["metadata"] || %{}, @reference),
        refunds: refunds(charge, intent["id"]),
        created_at: time(intent["created"])
      }
      |> Map.merge(buyer_of(intent, charge))
      |> Map.merge(charge_of(intent, charge))
      |> Payment.builder()
      |> MishkaPay.Errors.from_builder()
    end
  end

  # The buyer from the expanded customer, or from the charge's billing details.
  defp buyer_of(intent, charge) do
    customer = expanded(intent["customer"])
    billing = charge["billing_details"] || %{}

    %{
      customer_id: id_of(intent["customer"]),
      customer_email: customer["email"] || billing["email"] || intent["receipt_email"],
      customer_name: customer["name"] || billing["name"]
    }
  end

  # How it was paid, its receipt, and why the last try failed.
  defp charge_of(intent, charge) do
    card = get_in(charge, ["payment_method_details", "card"]) || %{}
    failure = intent["last_payment_error"] || %{}

    %{
      payment_method: get_in(charge, ["payment_method_details", "type"]),
      card_brand: card["brand"],
      card_last4: card["last4"],
      receipt_url: charge["receipt_url"],
      failure_code: failure["decline_code"] || failure["code"],
      failure_message: failure["message"]
    }
  end

  @subscription_statuses ~w(incomplete incomplete_expired trialing active past_due unpaid paused canceled)
  @invoice_statuses ~w(draft open paid uncollectible void)

  @doc """
  A Subscription, with its customer and its items' products expanded, as a
  `MishkaPay.Subscription`. The period comes from its items (Stripe moved it there), or from the
  subscription itself on older answers.
  """
  @spec subscription(map()) :: {:ok, Subscription.t()} | {:error, Splode.Error.t()}
  def subscription(sub) do
    items = get_in(sub, ["items", "data"]) || []
    first = List.first(items) || %{}
    customer = expanded(sub["customer"])

    %{
      provider: "stripe",
      id: sub["id"],
      status: known(sub["status"], @subscription_statuses),
      items: Enum.flat_map(items, &subscription_item/1),
      customer_id: id_of(sub["customer"]),
      customer_email: customer["email"],
      customer_name: customer["name"],
      current_period_start: time(first["current_period_start"] || sub["current_period_start"]),
      current_period_end: time(first["current_period_end"] || sub["current_period_end"]),
      cancel_at_period_end: sub["cancel_at_period_end"] == true,
      cancel_at: time(sub["cancel_at"]),
      canceled_at: time(sub["canceled_at"]),
      trial_end: time(sub["trial_end"]),
      latest_invoice_id: id_of(sub["latest_invoice"]),
      reference: get_in(sub, ["metadata", @reference]),
      metadata: Map.delete(sub["metadata"] || %{}, @reference),
      created_at: time(sub["created"])
    }
    |> Subscription.builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp subscription_item(%{"price" => %{} = price} = item) do
    case money(price["unit_amount"], price["currency"]) do
      nil ->
        []

      amount ->
        [
          %{
            id: price["id"],
            name: expanded(price["product"])["name"] || price["nickname"],
            amount: amount,
            quantity: item["quantity"] || 1,
            interval: interval(get_in(price, ["recurring", "interval"])),
            interval_count: get_in(price, ["recurring", "interval_count"])
          }
        ]
    end
  end

  defp subscription_item(_no_price), do: []

  defp interval(interval) when interval in ["day", "week", "month", "year"],
    do: String.to_existing_atom(interval)

  defp interval(_none), do: nil

  @doc "An Invoice as a `MishkaPay.Invoice`."
  @spec invoice(map()) :: {:ok, Invoice.t()} | {:error, Splode.Error.t()}
  def invoice(invoice) do
    %{
      provider: "stripe",
      id: invoice["id"],
      subscription_id: subscription_of(invoice),
      status: known(invoice["status"], @invoice_statuses),
      amount_due: money(invoice["amount_due"], invoice["currency"]),
      amount_paid: money(invoice["amount_paid"], invoice["currency"]),
      period_start: time(invoice["period_start"]),
      period_end: time(invoice["period_end"]),
      hosted_url: invoice["hosted_invoice_url"],
      pdf_url: invoice["invoice_pdf"],
      payment_id: id_of(invoice["payment_intent"]),
      created_at: time(invoice["created"])
    }
    |> Invoice.builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp known(value, values) when is_binary(value) do
    case value in values do
      true -> String.to_existing_atom(value)
      false -> nil
    end
  end

  defp known(_value, _values), do: nil

  defp refunds(%{"refunds" => %{"data" => refunds}}, payment_id) when is_list(refunds),
    do: Enum.flat_map(refunds, &refund_of(&1, payment_id))

  defp refunds(_charge, _payment_id), do: []

  defp refund_of(refund, payment_id) do
    case money(refund["amount"], refund["currency"]) do
      nil ->
        []

      amount ->
        [
          %{
            provider: "stripe",
            payment_id: payment_id,
            id: refund["id"],
            amount: amount,
            status: Map.get(@refund_statuses, refund["status"]),
            reason: Map.get(@refund_reasons, refund["reason"]),
            reference: get_in(refund, ["metadata", @reference]),
            created_at: time(refund["created"])
          }
        ]
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
      subscription_id: subscription_of(object),
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

  # The subscription itself, the one an invoice bills (on its own field, or under its parent since
  # Stripe moved it there), or the one a checkout started.
  defp subscription_of(%{"object" => "subscription", "id" => id}) when is_binary(id), do: id

  defp subscription_of(%{"parent" => %{"subscription_details" => %{"subscription" => sub}}}),
    do: id_of(sub)

  defp subscription_of(%{"subscription" => sub}), do: id_of(sub)
  defp subscription_of(_other), do: nil

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

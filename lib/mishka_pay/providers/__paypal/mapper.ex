# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.PayPal.Mapper do
  @moduledoc """
  Mishka Pay's structs to PayPal's request bodies, and PayPal's answers (Orders v2, captures,
  refunds, webhook events) back to Mishka Pay's structs. Pure: no request is made here.
  """

  alias MishkaPay.{Checkout, Event, Money, Payment, Price, Refund}

  @checkout_statuses %{
    "CREATED" => :open,
    "SAVED" => :open,
    "PAYER_ACTION_REQUIRED" => :open,
    "APPROVED" => :open,
    "COMPLETED" => :complete,
    "VOIDED" => :expired
  }

  @refund_statuses %{
    "COMPLETED" => :succeeded,
    "PENDING" => :pending,
    "FAILED" => :failed,
    "CANCELLED" => :canceled
  }

  @doc """
  The body of `POST /v2/checkout/orders`: one purchase unit with the items and their total, the
  reference as `custom_id`, and the return and cancel URLs for the buyer.
  """
  @spec order_params(Checkout.t()) :: map()
  def order_params(
        %Checkout{items: [%Price{amount: %{currency: currency}} | _] = items} = checkout
      ) do
    total = Enum.reduce(items, Decimal.new(0), &Decimal.add(&2, line_total(&1)))

    %{
      "intent" => "CAPTURE",
      "purchase_units" => [
        %{
          "custom_id" => checkout.reference,
          "amount" => %{
            "currency_code" => to_string(currency),
            "value" => value(total, currency),
            "breakdown" => %{
              "item_total" => %{
                "currency_code" => to_string(currency),
                "value" => value(total, currency)
              }
            }
          },
          "items" => Enum.map(items, &item/1)
        }
      ],
      "payment_source" => %{
        "paypal" =>
          %{
            "experience_context" => %{
              "return_url" => checkout.success_url,
              "cancel_url" => checkout.cancel_url,
              "user_action" => "PAY_NOW",
              "shipping_preference" => "NO_SHIPPING"
            }
          }
          |> Map.merge(email(checkout.customer))
      }
    }
  end

  defp item(%Price{name: name, amount: amount, quantity: quantity}) do
    %{
      "name" => String.slice(name, 0, 127),
      "quantity" => Integer.to_string(quantity),
      "unit_amount" => %{
        "currency_code" => to_string(amount.currency),
        "value" => value(amount.amount, amount.currency)
      }
    }
  end

  defp line_total(%Price{amount: amount, quantity: quantity}),
    do: Decimal.mult(amount.amount, quantity)

  defp email(%{email: email}) when is_binary(email), do: %{"email_address" => email}
  defp email(_none), do: %{}

  # PayPal's amounts are strings with the currency's own decimal places.
  defp value(amount, currency) do
    {_currency, _minor, exponent, _remainder} =
      currency |> Elixir.Money.new(amount) |> Elixir.Money.to_integer_exp()

    amount |> Decimal.round(-exponent) |> Decimal.to_string(:normal)
  end

  @doc "The checkout with PayPal's answer: the Order's id, its approval page and status."
  @spec checkout(map(), Checkout.t()) :: Checkout.t()
  def checkout(order, %Checkout{} = checkout) do
    %{
      checkout
      | id: order["id"],
        url: link(order, ["payer-action", "approve"]),
        status: Map.get(@checkout_statuses, order["status"]),
        payment_id: if(order["status"] == "COMPLETED", do: order["id"]),
        amount_total: unit_money(order, ["amount"])
    }
  end

  @doc "An Order read back on its own, as a checkout: what PayPal filled in and the reference."
  @spec checkout(map()) :: Checkout.t()
  def checkout(order) do
    read_back =
      struct(Checkout,
        provider: "paypal",
        items: [],
        reference: unit(order)["custom_id"],
        customer: buyer(get_in(order, ["payer", "email_address"]))
      )

    checkout(order, read_back)
  end

  defp buyer(email) when is_binary(email), do: struct(MishkaPay.Customer, email: email)
  defp buyer(_none), do: nil

  @doc """
  An Order as a `MishkaPay.Payment`: its id is the payment's id; its capture says whether it was
  paid, and the capture's refunds how much went back.
  """
  @spec payment(map()) :: {:ok, Payment.t()} | {:error, Splode.Error.t()}
  def payment(order) do
    case unit_money(order, ["amount"]) do
      %Elixir.Money{} = amount ->
        order |> payment_attrs(amount) |> Payment.builder() |> MishkaPay.Errors.from_builder()

      nil ->
        MishkaPay.ProviderKit.invalid(
          :amount,
          MishkaPay.Messages.text(:money_field, field: :amount)
        )
    end
  end

  defp payment_attrs(order, amount) do
    capture = capture(order)
    refunds = get_in(unit(order), ["payments", "refunds"]) || []
    refunded = refunded(refunds, amount)
    payer = order["payer"] || %{}
    card = get_in(order, ["payment_source", "card"]) || %{}
    reason = get_in(capture || %{}, ["status_details", "reason"])

    %{
      provider: "paypal",
      id: order["id"],
      amount: amount,
      amount_captured: captured(capture),
      amount_refunded: refunded,
      status: status(order, capture, refunded, amount),
      reference: unit(order)["custom_id"],
      customer_id: payer["payer_id"],
      customer_email: payer["email_address"],
      customer_name: name(payer["name"]),
      payment_method: method(order["payment_source"]),
      card_brand: card["brand"] && String.downcase(card["brand"]),
      card_last4: card["last_digits"],
      failure_code: reason,
      failure_message: reason,
      refunds: Enum.flat_map(refunds, &refund_of(&1, order["id"])),
      created_at: time(order["create_time"])
    }
  end

  @doc "The Order's capture, the payment PayPal took, or nil before it is captured."
  @spec capture(map()) :: map() | nil
  def capture(order),
    do: order |> unit() |> get_in(["payments", "captures"]) |> List.wrap() |> List.first()

  # What PayPal took: the capture's amount, once it is not declined, failed or still pending.
  defp captured(%{"status" => status} = capture)
       when status not in ["DECLINED", "FAILED", "PENDING"],
       do: money_of(capture["amount"])

  defp captured(_not_taken), do: nil

  defp status(%{"status" => "VOIDED"}, _capture, _refunded, _amount), do: :canceled

  defp status(_order, %{"status" => status}, _refunded, _amount)
       when status in ["DECLINED", "FAILED"],
       do: :failed

  defp status(_order, %{"status" => "PENDING"}, _refunded, _amount), do: :pending

  defp status(_order, %{"status" => _taken}, refunded, amount) do
    cond do
      not Elixir.Money.positive?(refunded) -> :paid
      Decimal.lt?(refunded.amount, amount.amount) -> :partially_refunded
      true -> :refunded
    end
  end

  defp status(_order, nil, _refunded, _amount), do: :pending

  defp refunded(refunds, amount) do
    refunds
    |> Enum.filter(&(&1["status"] in ["COMPLETED", "PENDING"]))
    |> Enum.reduce(Elixir.Money.new(amount.currency, 0), fn refund, sum ->
      case money_of(refund["amount"]) do
        %Elixir.Money{} = money -> Elixir.Money.add!(sum, money)
        nil -> sum
      end
    end)
  end

  defp refund_of(refund, order_id) do
    case money_of(refund["amount"]) do
      nil ->
        []

      amount ->
        [
          %{
            provider: "paypal",
            payment_id: order_id,
            id: refund["id"],
            amount: amount,
            status: Map.get(@refund_statuses, refund["status"]),
            created_at: time(refund["create_time"])
          }
        ]
    end
  end

  @doc "The body of `POST /v2/payments/captures/{id}/refund`: the amount when it is not the whole."
  @spec refund_params(Refund.t()) :: map()
  def refund_params(%Refund{amount: nil}), do: %{}

  def refund_params(%Refund{amount: amount}),
    do: %{
      "amount" => %{
        "currency_code" => to_string(amount.currency),
        "value" => value(amount.amount, amount.currency)
      }
    }

  @doc "The refund with PayPal's answer: its id, status, amount and time."
  @spec refund(map(), Refund.t()) :: {:ok, Refund.t()} | {:error, Splode.Error.t()}
  def refund(answer, %Refund{} = refund) do
    {:ok,
     %{
       refund
       | id: answer["id"],
         status: Map.get(@refund_statuses, answer["status"]),
         amount: money_of(answer["amount"]) || refund.amount,
         created_at: time(answer["create_time"])
     }}
  end

  @doc """
  A PayPal webhook event as a `MishkaPay.Event`, naming the Order it concerns: the Order itself,
  or the Order a capture or refund belongs to. `live?` says whose keys checked it.
  """
  @spec event(map(), boolean()) :: {:ok, Event.t()} | {:error, Splode.Error.t()}
  def event(event, live?) do
    resource = event["resource"] || %{}

    %{
      provider: "paypal",
      id: event["id"],
      type: event["event_type"],
      object_id: resource["id"],
      object_type: event["resource_type"],
      payment_id: order_of(event["resource_type"], resource),
      livemode: live?,
      created_at: time(event["create_time"])
    }
    |> Event.builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp order_of("checkout-order", %{"id" => id}), do: id

  defp order_of(_capture_or_refund, resource),
    do: get_in(resource, ["supplementary_data", "related_ids", "order_id"])

  defp unit(order), do: order |> Map.get("purchase_units", []) |> List.first() || %{}

  defp unit_money(order, path), do: order |> unit() |> get_in(path) |> money_of()

  defp money_of(%{"currency_code" => currency, "value" => value}) when is_binary(value) do
    case Money.field(:amount, %{amount: value, currency: currency}) do
      {:ok, :amount, money} -> money
      _invalid -> nil
    end
  end

  defp money_of(_none), do: nil

  defp link(order, rels) do
    Enum.find_value(order["links"] || [], fn
      %{"rel" => rel, "href" => href} -> if rel in rels, do: href
      _other -> nil
    end)
  end

  defp method(%{} = source) when map_size(source) > 0, do: source |> Map.keys() |> List.first()
  defp method(_none), do: nil

  defp name(%{"given_name" => given, "surname" => surname}), do: "#{given} #{surname}"
  defp name(%{"full_name" => full}), do: full
  defp name(_none), do: nil

  defp time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, time, _offset} -> time
      _not_a_time -> nil
    end
  end

  defp time(_none), do: nil
end

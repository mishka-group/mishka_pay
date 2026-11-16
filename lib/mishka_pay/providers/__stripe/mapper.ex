# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.Stripe.Mapper do
  @moduledoc """
  The only place that knows Stripe's field names: Mishka Pay's structs become Stripe's params, and
  Stripe's JSON objects (API version `2026-10-28.endive`) become Mishka Pay's structs.
  """

  alias MishkaPay.{
    Checkout,
    Coupon,
    Customer,
    Event,
    Invoice,
    Money,
    Payment,
    PaymentLink,
    Price,
    Product,
    PromotionCode,
    Refund,
    Subscription
  }

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
    |> Map.merge(buyer_params(checkout.customer))
    |> Map.merge(managed_payments(merchant_of_record(checkout, settings)))
    |> Map.merge(options(checkout))
    |> Map.merge(automatic_tax(checkout, settings))
  end

  # The checkout's own choice, else the tenant's default, else the Stripe account's (not sent).
  defp automatic_tax(%{automatic_tax: choice}, _settings) when is_boolean(choice),
    do: %{"automatic_tax" => %{"enabled" => choice}}

  defp automatic_tax(_checkout, %{automatic_tax: true}),
    do: %{"automatic_tax" => %{"enabled" => true}}

  defp automatic_tax(_checkout, _settings), do: %{}

  # The checkout's options, each only when it is set.
  defp options(%Checkout{} = checkout) do
    %{
      "discounts" => discounts(checkout.discounts),
      "allow_promotion_codes" => checkout.allow_promotion_codes,
      "customer_creation" => checkout.customer_creation && to_string(checkout.customer_creation),
      "locale" => checkout.locale,
      "expires_at" => checkout.expires_at && DateTime.to_unix(checkout.expires_at),
      "billing_address_collection" =>
        checkout.billing_address && to_string(checkout.billing_address),
      "tax_id_collection" => enabled(checkout.tax_id_collection),
      "invoice_creation" => enabled(checkout.invoice)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp discounts(nil), do: nil
  defp discounts([]), do: nil
  defp discounts(discounts), do: Enum.map(discounts, &discount/1)

  defp discount(%{coupon_id: id}) when is_binary(id), do: %{"coupon" => id}
  defp discount(%{promotion_code_id: id}), do: %{"promotion_code" => id}

  defp enabled(nil), do: nil
  defp enabled(on?), do: %{"enabled" => on?}

  defp mode_data(%Checkout{mode: :subscription, trial_days: days}, reference),
    do: %{
      "subscription_data" => %{"metadata" => reference, "trial_period_days" => days}
    }

  defp mode_data(_payment, reference), do: %{"payment_intent_data" => %{"metadata" => reference}}

  # The checkout's own choice, else the tenant's setting, else nil: the Stripe account's default.
  defp merchant_of_record(%{merchant_of_record: choice}, _settings)
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
          "product_data" => %{"name" => name, "tax_code" => tax_code},
          "tax_behavior" => price.tax_behavior && Atom.to_string(price.tax_behavior)
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.merge(recurring(price)),
      "quantity" => quantity
    }
  end

  defp recurring(%Price{interval: nil}), do: %{}

  defp recurring(%Price{interval: interval, interval_count: count}),
    do: %{"recurring" => %{"interval" => Atom.to_string(interval), "interval_count" => count}}

  defp buyer_params(%{id: id}) when is_binary(id), do: %{"customer" => id}
  defp buyer_params(%{email: email}) when is_binary(email), do: %{"customer_email" => email}
  defp buyer_params(_none), do: %{}

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
        amount_tax: money(get_in(session, ["total_details", "amount_tax"]), session["currency"]),
        amount_discount:
          money(get_in(session, ["total_details", "amount_discount"]), session["currency"]),
        expires_at: time(session["expires_at"]),
        invoice_id: id_of(session["invoice"]),
        payment_link_id: id_of(session["payment_link"])
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

  defp signed_money(minor, currency) when is_integer(minor) and is_binary(currency) do
    case Money.signed_from_minor(minor, currency) do
      {:ok, money} -> money
      {:error, _odd} -> nil
    end
  end

  defp signed_money(_minor, _currency), do: nil

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
        disputed: charge["disputed"] == true,
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
      pause_behavior: get_in(sub, ["pause_collection", "behavior"]),
      resumes_at: time(get_in(sub, ["pause_collection", "resumes_at"])),
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
            item_id: item["id"],
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

  @doc """
  Params of `POST /v1/customers` (and its update): the fields set, the reference in the metadata.
  A field left out is not sent, so an update changes only what it names.
  """
  @spec customer_params(Customer.t()) :: map()
  def customer_params(%Customer{} = customer) do
    metadata =
      case customer.reference do
        nil -> customer.metadata
        reference -> Map.put(customer.metadata || %{}, @reference, reference)
      end

    %{
      "email" => customer.email,
      "name" => customer.name,
      "phone" => customer.phone,
      "metadata" => metadata
    }
  end

  @doc "A Customer as a `MishkaPay.Customer`; a deleted one is a rejection."
  @spec customer(map()) :: {:ok, Customer.t()} | {:error, Splode.Error.t()}
  def customer(%{"deleted" => true, "id" => id}) do
    {:error,
     MishkaPay.Errors.Rejected.exception(
       provider: "stripe",
       status: 404,
       code: "customer_deleted",
       message: "Customer #{id} was deleted"
     )}
  end

  def customer(customer) do
    %{
      provider: "stripe",
      id: customer["id"],
      email: customer["email"],
      name: customer["name"],
      phone: customer["phone"],
      reference: get_in(customer, ["metadata", @reference]),
      metadata: Map.delete(customer["metadata"] || %{}, @reference),
      default_payment_method:
        id_of(get_in(customer, ["invoice_settings", "default_payment_method"])),
      created_at: time(customer["created"])
    }
    |> Map.reject(fn {_field, value} -> value == "" end)
    |> Customer.builder()
    |> MishkaPay.Errors.from_builder()
  end

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
      total: money(invoice["total"], invoice["currency"]),
      amount_tax: money(tax_of(invoice), invoice["currency"]),
      lines:
        invoice
        |> get_in(["lines", "data"])
        |> List.wrap()
        |> Enum.map(&line(&1, invoice["currency"])),
      customer_id: id_of(invoice["customer"]),
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

  # Stripe sums an invoice's taxes in `total_taxes`.
  defp tax_of(%{"total_taxes" => taxes}) when is_list(taxes),
    do: Enum.reduce(taxes, 0, &((&1["amount"] || 0) + &2))

  defp tax_of(_no_taxes), do: nil

  defp line(line, currency) do
    %{
      description: line["description"],
      amount: signed_money(line["amount"], currency),
      quantity: line["quantity"],
      price_id: id_of(get_in(line, ["pricing", "price_details", "price"])),
      proration:
        get_in(line, ["parent", "subscription_item_details", "proration"]) == true or
          line["proration"] == true,
      period_start: time(get_in(line, ["period", "start"])),
      period_end: time(get_in(line, ["period", "end"]))
    }
  end

  @doc """
  Params of `POST /v1/subscriptions/:id` for a change: the item with its new price and quantity,
  and how the difference is billed; only what the change sets.
  """
  @spec change_params(MishkaPay.SubscriptionChange.t(), String.t()) :: map()
  def change_params(change, item_id) do
    %{
      "items" => [change_item(change, item_id)],
      "proration_behavior" => change.proration && to_string(change.proration),
      "proration_date" => change.proration_date && DateTime.to_unix(change.proration_date),
      "billing_cycle_anchor" =>
        change.billing_cycle_anchor && %{"type" => to_string(change.billing_cycle_anchor)},
      "payment_behavior" => change.payment_behavior && to_string(change.payment_behavior)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc "Params of `POST /v1/invoices/create_preview` for the same change, without making it."
  @spec preview_params(MishkaPay.SubscriptionChange.t(), String.t()) :: map()
  def preview_params(change, item_id) do
    details =
      change
      |> change_params(item_id)
      |> Map.drop(["payment_behavior"])

    %{"subscription" => change.subscription_id, "subscription_details" => details}
  end

  defp change_item(change, item_id) do
    %{"id" => item_id, "price" => change.price_id, "quantity" => change.quantity}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
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
      dispute_id: dispute_of(object),
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

  # An invoice payment names its PaymentIntent under `payment`.
  defp payment_of(%{"object" => "invoice_payment", "payment" => %{"payment_intent" => payment}}),
    do: id_of(payment)

  defp payment_of(_other), do: nil

  # The subscription itself, the one an invoice bills (on its own field, or under its parent since
  # Stripe moved it there), or the one a checkout started.
  defp subscription_of(%{"object" => "subscription", "id" => id}) when is_binary(id), do: id

  defp subscription_of(%{"parent" => %{"subscription_details" => %{"subscription" => sub}}}),
    do: id_of(sub)

  defp subscription_of(%{"subscription" => sub}), do: id_of(sub)
  defp subscription_of(_other), do: nil

  defp dispute_of(%{"object" => "dispute", "id" => id}) when is_binary(id), do: id
  defp dispute_of(_other), do: nil

  @dispute_statuses ~w(warning_needs_response warning_under_review warning_closed needs_response under_review won lost prevented)

  @doc "A Stripe dispute as a `MishkaPay.Dispute`."
  @spec dispute(map()) :: {:ok, MishkaPay.Dispute.t()} | {:error, Splode.Error.t()}
  def dispute(dispute) do
    details = dispute["evidence_details"] || %{}

    %{
      provider: "stripe",
      id: dispute["id"],
      payment_id: id_of(dispute["payment_intent"]),
      charge_id: id_of(dispute["charge"]),
      amount: money(dispute["amount"], dispute["currency"]),
      status: known(dispute["status"], @dispute_statuses),
      reason: dispute["reason"],
      evidence_due_by: time(details["due_by"]),
      has_evidence: details["has_evidence"] == true,
      submission_count: details["submission_count"] || 0,
      refundable: dispute["is_charge_refundable"],
      metadata: dispute["metadata"],
      created_at: time(dispute["created"])
    }
    |> MishkaPay.Dispute.builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp object_of(%{"data" => %{"object" => %{} = object}}), do: object
  defp object_of(_no_object), do: %{}

  defp expanded(%{} = object), do: object
  defp expanded(_id_or_nil), do: %{}

  defp id_of(%{"id" => id}), do: id
  defp id_of(id) when is_binary(id), do: id
  defp id_of(_none), do: nil

  @doc "Params of `POST /v1/coupons`: what it takes off, for how long, and its limits."
  @spec coupon_params(Coupon.t()) :: map()
  def coupon_params(%Coupon{} = coupon) do
    %{
      "id" => coupon.id,
      "name" => coupon.name,
      "percent_off" => coupon.percent_off && Decimal.to_string(coupon.percent_off, :normal),
      "amount_off" => coupon.amount_off && Money.to_minor(coupon.amount_off),
      "currency" => coupon.amount_off && lower_currency(coupon.amount_off),
      "duration" => Atom.to_string(coupon.duration),
      "duration_in_months" => coupon.duration_in_months,
      "max_redemptions" => coupon.max_redemptions,
      "redeem_by" => coupon.redeem_by && DateTime.to_unix(coupon.redeem_by),
      "metadata" => coupon.metadata
    }
  end

  @doc "A Stripe coupon as a `MishkaPay.Coupon`."
  @spec coupon(map()) :: {:ok, Coupon.t()} | {:error, Splode.Error.t()}
  def coupon(coupon) do
    %{
      provider: "stripe",
      id: coupon["id"],
      name: coupon["name"],
      percent_off: coupon["percent_off"],
      amount_off: money(coupon["amount_off"], coupon["currency"]),
      duration: coupon["duration"],
      duration_in_months: coupon["duration_in_months"],
      max_redemptions: coupon["max_redemptions"],
      redeem_by: time(coupon["redeem_by"]),
      metadata: coupon["metadata"],
      valid: coupon["valid"] == true,
      times_redeemed: coupon["times_redeemed"],
      created_at: time(coupon["created"])
    }
    |> blank_names()
    |> Coupon.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc """
  Params of `POST /v1/promotion_codes`: the coupon it applies (as Stripe's `promotion`), the code
  and its own limits.
  """
  @spec promotion_code_params(PromotionCode.t()) :: map()
  def promotion_code_params(%PromotionCode{} = code) do
    %{
      "promotion" => %{"type" => "coupon", "coupon" => code.coupon_id},
      "code" => code.code,
      "active" => code.active,
      "max_redemptions" => code.max_redemptions,
      "expires_at" => code.expires_at && DateTime.to_unix(code.expires_at),
      "customer" => code.customer_id,
      "restrictions" => restrictions(code),
      "metadata" => code.metadata
    }
  end

  defp restrictions(%PromotionCode{first_time_transaction: first, minimum_amount: minimum}) do
    %{
      "first_time_transaction" => first,
      "minimum_amount" => minimum && Money.to_minor(minimum),
      "minimum_amount_currency" => minimum && lower_currency(minimum)
    }
  end

  @doc "Params of `POST /v1/promotion_codes/:id`: only whether it is active, and its metadata."
  @spec promotion_code_update_params(PromotionCode.t()) :: map()
  def promotion_code_update_params(%PromotionCode{} = code),
    do: %{"active" => code.active, "metadata" => code.metadata}

  @doc "A Stripe promotion code as a `MishkaPay.PromotionCode`."
  @spec promotion_code(map()) :: {:ok, PromotionCode.t()} | {:error, Splode.Error.t()}
  def promotion_code(code) do
    restrictions = code["restrictions"] || %{}

    %{
      provider: "stripe",
      id: code["id"],
      code: code["code"],
      coupon_id: id_of(get_in(code, ["promotion", "coupon"])),
      active: code["active"],
      max_redemptions: code["max_redemptions"],
      expires_at: time(code["expires_at"]),
      first_time_transaction: restrictions["first_time_transaction"],
      minimum_amount:
        money(restrictions["minimum_amount"], restrictions["minimum_amount_currency"]),
      customer_id: id_of(code["customer"]),
      metadata: code["metadata"],
      times_redeemed: code["times_redeemed"],
      created_at: time(code["created"])
    }
    |> PromotionCode.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc "Params of `POST /v1/products` (and its update): only the fields set."
  @spec product_params(Product.t()) :: map()
  def product_params(%Product{} = product) do
    %{
      "id" => product.id,
      "name" => product.name,
      "description" => product.description,
      "tax_code" => product.tax_code,
      "active" => product.active,
      "metadata" => product.metadata
    }
  end

  @doc "A Stripe product as a `MishkaPay.Product`."
  @spec product(map()) :: {:ok, Product.t()} | {:error, Splode.Error.t()}
  def product(product) do
    %{
      provider: "stripe",
      id: product["id"],
      name: product["name"],
      description: blank(product["description"]),
      tax_code: id_of(product["tax_code"]),
      active: product["active"],
      metadata: product["metadata"],
      default_price_id: id_of(product["default_price"]),
      created_at: time(product["created"])
    }
    |> Product.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc "Params of `POST /v1/prices`: the product, the amount, and the schedule of a plan."
  @spec price_params(Price.t()) :: map()
  def price_params(%Price{} = price) do
    %{
      "product" => price.product_id,
      "currency" => lower_currency(price.amount),
      "unit_amount" => Money.to_minor(price.amount),
      "nickname" => price.name,
      "lookup_key" => price.lookup_key,
      "tax_behavior" => price.tax_behavior && Atom.to_string(price.tax_behavior),
      "metadata" => price.metadata
    }
    |> Map.merge(recurring(price))
  end

  @doc """
  A Stripe price as a catalog `MishkaPay.Price`: named after its product when the product is
  expanded, else its nickname.
  """
  @spec price(map()) :: {:ok, Price.t()} | {:error, Splode.Error.t()}
  def price(price) do
    %{
      provider: "stripe",
      id: price["id"],
      name: expanded(price["product"])["name"] || blank(price["nickname"]),
      amount: money(price["unit_amount"], price["currency"]),
      product_id: id_of(price["product"]),
      lookup_key: price["lookup_key"],
      active: price["active"],
      interval: interval(get_in(price, ["recurring", "interval"])),
      interval_count: get_in(price, ["recurring", "interval_count"]),
      tax_behavior: tax_behavior(price["tax_behavior"]),
      tax_code: id_of(expanded(price["product"])["tax_code"]),
      metadata: price["metadata"],
      created_at: time(price["created"])
    }
    |> Price.builder()
    |> MishkaPay.Errors.from_builder()
  end

  # Stripe's third choice, "unspecified", is a price that never said.
  defp tax_behavior(behavior) when behavior in ["inclusive", "exclusive"],
    do: String.to_existing_atom(behavior)

  defp tax_behavior(_unspecified), do: nil

  @doc """
  Params of `POST /v1/payment_links`: its prices, where the buyer goes after paying, and the
  options a checkout has; the tenant's automatic tax when the link does not say.
  """
  @spec payment_link_params(PaymentLink.t(), map()) :: map()
  def payment_link_params(%PaymentLink{} = link, settings \\ %{}) do
    %{
      "line_items" => Enum.map(link.items, &link_item(&1, link)),
      "after_completion" => after_completion(link.success_url),
      "restrictions" =>
        link.max_purchases && %{"completed_sessions" => %{"limit" => link.max_purchases}},
      "inactive_message" => link.inactive_message,
      "customer_creation" => link.customer_creation && to_string(link.customer_creation),
      "billing_address_collection" => link.billing_address && to_string(link.billing_address),
      "tax_id_collection" => enabled(link.tax_id_collection),
      "allow_promotion_codes" => link.allow_promotion_codes,
      "invoice_creation" => enabled(link.invoice),
      "subscription_data" => link.trial_days && %{"trial_period_days" => link.trial_days},
      "metadata" => link.metadata
    }
    |> Map.merge(automatic_tax(link, settings))
    |> Map.merge(managed_payments(merchant_of_record(link, settings)))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  Params of `POST /v1/payment_links/:id`: every option set on the link, on or off, its limits and
  messages; its prices and trial stay as made.
  """
  @spec payment_link_update_params(PaymentLink.t()) :: map()
  def payment_link_update_params(%PaymentLink{} = link) do
    link
    |> Map.put(:items, [])
    |> payment_link_params()
    |> Map.drop(["line_items", "subscription_data"])
    |> Map.put("active", link.active)
  end

  # The buyer may change the quantity when the link gives a range.
  defp link_item(price, %{quantity_min: nil, quantity_max: nil}),
    do: %{"price" => price.id, "quantity" => price.quantity}

  defp link_item(price, link) do
    %{
      "price" => price.id,
      "quantity" => price.quantity,
      "adjustable_quantity" => %{
        "enabled" => true,
        "minimum" => link.quantity_min,
        "maximum" => link.quantity_max
      }
    }
  end

  defp after_completion(nil), do: nil

  defp after_completion(url),
    do: %{"type" => "redirect", "redirect" => %{"url" => url}}

  @doc "A Stripe payment link as a `MishkaPay.PaymentLink`, with its line items when expanded."
  @spec payment_link(map()) :: {:ok, PaymentLink.t()} | {:error, Splode.Error.t()}
  def payment_link(link) do
    %{
      provider: "stripe",
      id: link["id"],
      url: link["url"],
      active: link["active"],
      items: link_items(link["line_items"]),
      quantity_min: link_quantity(link["line_items"], "minimum"),
      quantity_max: link_quantity(link["line_items"], "maximum"),
      success_url: get_in(link, ["after_completion", "redirect", "url"]),
      allow_promotion_codes: link["allow_promotion_codes"],
      automatic_tax: get_in(link, ["automatic_tax", "enabled"]),
      invoice: get_in(link, ["invoice_creation", "enabled"]),
      trial_days: get_in(link, ["subscription_data", "trial_period_days"]),
      max_purchases: get_in(link, ["restrictions", "completed_sessions", "limit"]),
      purchases: get_in(link, ["restrictions", "completed_sessions", "count"]),
      inactive_message: link["inactive_message"],
      customer_creation: link["customer_creation"],
      billing_address: link["billing_address_collection"],
      tax_id_collection: get_in(link, ["tax_id_collection", "enabled"]),
      metadata: link["metadata"],
      created_at: time(link["created"])
    }
    |> PaymentLink.builder()
    |> MishkaPay.Errors.from_builder()
  end

  # Stripe lists a link's line items only when asked (`expand[]=line_items`).
  defp link_items(%{"data" => items}) do
    for %{"price" => price} = item <- items do
      %{id: id_of(price), quantity: item["quantity"] || 1}
    end
  end

  defp link_items(_not_expanded), do: nil

  # The quantity range the buyer may pick is kept on each line item; Mishka Pay sets one for all.
  # Stripe answers a minimum of 0 when none was given: that is its default, not a choice.
  defp link_quantity(%{"data" => items}, bound) do
    Enum.find_value(items, fn
      %{"adjustable_quantity" => %{"enabled" => true} = range} -> positive(range[bound])
      _fixed -> nil
    end)
  end

  defp link_quantity(_not_expanded, _bound), do: nil

  defp positive(number) when is_integer(number) and number > 0, do: number
  defp positive(_none), do: nil

  defp blank(""), do: nil
  defp blank(text), do: text

  # Stripe keeps an unnamed coupon's name as null or empty.
  defp blank_names(%{name: ""} = attrs), do: %{attrs | name: nil}
  defp blank_names(attrs), do: attrs

  defp lower_currency(%{currency: currency}),
    do: currency |> to_string() |> String.downcase()

  defp time(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, time} -> time
      {:error, _out_of_range} -> nil
    end
  end

  defp time(_none), do: nil
end

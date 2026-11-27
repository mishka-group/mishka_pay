# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.PayPal.Mapper do
  @moduledoc """
  Mishka Pay's structs to PayPal's request bodies, and PayPal's answers (Orders v2, captures,
  refunds, catalog products, billing plans, subscriptions and their transactions, webhook events)
  back to Mishka Pay's structs. Pure: no request is made here.
  """

  alias MishkaPay.{Checkout, Event, Invoice, Money, Payment, Price, Refund, Subscription}

  @checkout_statuses %{
    "CREATED" => :open,
    "SAVED" => :open,
    "PAYER_ACTION_REQUIRED" => :open,
    "APPROVED" => :open,
    "COMPLETED" => :complete,
    "VOIDED" => :expired
  }

  @subscription_statuses %{
    "APPROVAL_PENDING" => :incomplete,
    "APPROVED" => :incomplete,
    "ACTIVE" => :active,
    "SUSPENDED" => :paused,
    "CANCELLED" => :canceled,
    "EXPIRED" => :canceled
  }

  @transaction_statuses %{
    "COMPLETED" => :paid,
    "PARTIALLY_REFUNDED" => :paid,
    "REFUNDED" => :paid,
    "PENDING" => :open,
    "DECLINED" => :uncollectible
  }

  @units %{day: "DAY", week: "WEEK", month: "MONTH", year: "YEAR"}
  @intervals Map.new(@units, fn {interval, unit} -> {unit, interval} end)

  @refund_statuses %{
    "COMPLETED" => :succeeded,
    "PENDING" => :pending,
    "FAILED" => :failed,
    "CANCELLED" => :canceled
  }

  @doc """
  The body of `POST /v2/checkout/orders`: one purchase unit with the items and their total, the
  reference as `custom_id`, the return and cancel URLs for the buyer, and the buyer's email and
  address when the checkout's customer has them (`payment_source.paypal.address`, where PayPal's
  page starts, the country alone included). A line with its own
  `:tax_percentage` carries its tax on each item (an inclusive amount is split into the part
  before tax and the tax), and the unit's amount is the items' total with the `tax_total` added.
  """
  @spec order_params(Checkout.t()) :: map()
  def order_params(
        %Checkout{items: [%Price{amount: %{currency: currency}} | _] = items} = checkout
      ) do
    lines = Enum.map(items, &{&1, split_tax(&1)})
    item_total = sum(lines, fn {price, {unit, _tax}} -> Decimal.mult(unit, price.quantity) end)
    tax_total = sum(lines, fn {price, {_unit, tax}} -> Decimal.mult(tax || 0, price.quantity) end)
    taxed? = Enum.any?(lines, fn {_price, {_unit, tax}} -> not is_nil(tax) end)

    %{
      "intent" => "CAPTURE",
      "purchase_units" => [
        %{
          "custom_id" => custom_id(checkout),
          "amount" => %{
            "currency_code" => to_string(currency),
            "value" => value(Decimal.add(item_total, tax_total), currency),
            "breakdown" => breakdown(item_total, tax_total, taxed?, currency)
          },
          "items" => Enum.map(lines, &item/1)
        }
      ],
      "payment_source" => %{
        "paypal" =>
          %{
            "experience_context" => %{
              "return_url" => without_session(checkout.success_url),
              "cancel_url" => without_session(checkout.cancel_url),
              "user_action" => "PAY_NOW",
              "shipping_preference" => "NO_SHIPPING"
            }
          }
          |> Map.merge(email(checkout.customer))
          |> Map.merge(payer_address(checkout.customer))
      }
    }
  end

  # The buyer's address the shop already knows, such as only their country, which PayPal's page
  # starts on for a buyer who pays without an account; the buyer changes it there.
  defp payer_address(%{address: %MishkaPay.Address{country: <<_a, _b>>} = address}) do
    %{
      "address" =>
        %{
          "country_code" => address.country,
          "postal_code" => address.postal_code,
          "address_line_1" => address.line1,
          "address_line_2" => address.line2,
          "admin_area_2" => address.city,
          "admin_area_1" => address.state
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    }
  end

  defp payer_address(_none), do: %{}

  defp breakdown(item_total, tax_total, taxed?, currency) do
    %{"item_total" => money_param(item_total, currency)}
    |> Map.merge(if taxed?, do: %{"tax_total" => money_param(tax_total, currency)}, else: %{})
  end

  defp item({%Price{name: name, amount: amount, quantity: quantity}, {unit, tax}}) do
    %{
      "name" => String.slice(name, 0, 127),
      "quantity" => Integer.to_string(quantity),
      "unit_amount" => money_param(unit, amount.currency)
    }
    |> Map.merge(if tax, do: %{"tax" => money_param(tax, amount.currency)}, else: %{})
  end

  # One unit of a line as PayPal takes it: the amount before tax and the tax on it, each rounded to
  # the currency; no tax for a line with no percentage of its own.
  defp split_tax(%Price{tax_percentage: nil, amount: amount}), do: {amount.amount, nil}

  defp split_tax(%Price{tax_percentage: percentage, amount: amount} = price) do
    rate = Decimal.div(percentage, 100)

    case price.tax_behavior do
      :inclusive ->
        unit = amount.amount |> Decimal.div(Decimal.add(1, rate)) |> rounded(amount.currency)
        {unit, Decimal.sub(amount.amount, unit)}

      _exclusive ->
        {amount.amount, amount.amount |> Decimal.mult(rate) |> rounded(amount.currency)}
    end
  end

  defp sum(lines, fun), do: Enum.reduce(lines, Decimal.new(0), &Decimal.add(&2, fun.(&1)))

  defp money_param(amount, currency),
    do: %{"currency_code" => to_string(currency), "value" => value(amount, currency)}

  defp email(%{email: email}) when is_binary(email), do: %{"email_address" => email}
  defp email(_none), do: %{}

  # PayPal's amounts are strings with the currency's own decimal places.
  defp value(amount, currency), do: amount |> rounded(currency) |> Decimal.to_string(:normal)

  defp rounded(amount, currency) do
    {_currency, _minor, exponent, _remainder} =
      currency |> Elixir.Money.new(amount) |> Elixir.Money.to_integer_exp()

    Decimal.round(amount, -exponent)
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
        amount_total: unit_money(order, ["amount"]),
        amount_tax: unit_money(order, ["amount", "breakdown", "tax_total"])
    }
  end

  @doc "An Order read back on its own, as a checkout: what PayPal filled in and the reference."
  @spec checkout(map()) :: Checkout.t()
  def checkout(order) do
    read_back =
      struct(Checkout,
        provider: "paypal",
        items: [],
        reference: reference(unit(order)["custom_id"]),
        owner: owner(unit(order)["custom_id"]),
        customer: buyer(get_in(order, ["payer", "email_address"]))
      )

    checkout(order, read_back)
  end

  defp buyer(email) when is_binary(email), do: struct(MishkaPay.Customer, email: email)
  defp buyer(_none), do: nil

  @doc """
  An Order as a `MishkaPay.Payment`: its id is the payment's id; its capture says whether it was
  paid (its id is the payment's `:charge_id`, its PayPal fee the `:fee`), and the capture's
  refunds how much went back. It is `:disputed` when `disputed?` says a buyer's dispute holds the
  capture (the adapter reads the capture's disputes), and when PayPal reversed the capture.
  """
  @spec payment(map(), boolean()) :: {:ok, Payment.t()} | {:error, Splode.Error.t()}
  def payment(order, disputed? \\ false) do
    case unit_money(order, ["amount"]) do
      %Elixir.Money{} = amount ->
        order
        |> payment_attrs(amount)
        |> Map.update!(:disputed, &(&1 or disputed?))
        |> Payment.builder()
        |> MishkaPay.Errors.from_builder()

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
      reference: reference(unit(order)["custom_id"]),
      owner: owner(unit(order)["custom_id"]),
      customer_id: payer["payer_id"],
      customer_email: payer["email_address"],
      customer_name: name(payer["name"]),
      payment_method: method(order["payment_source"]),
      card_brand: card["brand"] && String.downcase(card["brand"]),
      card_last4: card["last_digits"],
      charge_id: capture && capture["id"],
      fee: capture && money_of(get_in(capture, ["seller_receivable_breakdown", "paypal_fee"])),
      failure_code: reason,
      failure_message: reason,
      refunds: Enum.flat_map(refunds, &refund_of(&1, order["id"])),
      disputed: reversed?(capture),
      created_at: time(order["create_time"])
    }
  end

  # A capture PayPal reversed was taken back by the buyer's bank (a chargeback): the money is gone
  # whatever the Order still says, so the payment reads as disputed.
  defp reversed?(%{"status" => "REVERSED"}), do: true
  defp reversed?(_capture), do: false

  # How a dispute may end that leaves the seller the money (`dispute_outcome.outcome_code`).
  @seller_outcomes ["RESOLVED_SELLER_FAVOUR", "CANCELED_BY_BUYER", "DENIED"]

  @doc """
  Whether a resolved dispute (`GET /v1/customer/disputes/{id}`) left the seller the money: PayPal
  decided for the seller, the buyer withdrew it, or the claim was denied.
  """
  @spec settled_for_seller?(map()) :: boolean()
  def settled_for_seller?(%{"dispute_outcome" => %{"outcome_code" => code}}),
    do: code in @seller_outcomes

  def settled_for_seller?(_dispute), do: false

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

  @doc "The body of `POST /v1/catalogs/products`: the product a subscription's plan sells."
  @spec product_params(Price.t()) :: map()
  def product_params(%Price{name: name}),
    do: %{"name" => String.slice(name, 0, 127), "type" => "SERVICE"}

  @doc """
  The body of `POST /v1/billing/plans`: the price's amount charged every interval, with no end,
  after a free trial of the checkout's `:trial_days` when it has one. A quantity is allowed, so
  the plan charges the amount for each one. A price with its own `:tax_percentage` gives the plan
  that tax, held in the amount when its `:tax_behavior` is `:inclusive`.
  """
  @spec plan_params(String.t(), Price.t(), Checkout.t()) :: map()
  def plan_params(product_id, %Price{} = price, %Checkout{trial_days: trial_days}) do
    regular = %{
      "tenure_type" => "REGULAR",
      "total_cycles" => 0,
      "frequency" => %{
        "interval_unit" => Map.fetch!(@units, price.interval),
        "interval_count" => price.interval_count || 1
      },
      "pricing_scheme" => %{
        "fixed_price" => %{
          "currency_code" => to_string(price.amount.currency),
          "value" => value(price.amount.amount, price.amount.currency)
        }
      }
    }

    %{
      "product_id" => product_id,
      "name" => String.slice(price.name, 0, 127),
      "quantity_supported" => true,
      "billing_cycles" => cycles(trial_days, regular),
      "payment_preferences" => %{
        "auto_bill_outstanding" => true,
        "payment_failure_threshold" => 3
      }
    }
    |> Map.merge(plan_taxes(price))
  end

  defp plan_taxes(%Price{tax_percentage: nil}), do: %{}

  defp plan_taxes(%Price{tax_percentage: percentage, tax_behavior: behavior}),
    do: %{
      "taxes" => %{
        "percentage" => Decimal.to_string(percentage, :normal),
        "inclusive" => behavior == :inclusive
      }
    }

  defp cycles(nil, regular), do: [Map.put(regular, "sequence", 1)]

  defp cycles(days, regular) do
    trial = %{
      "tenure_type" => "TRIAL",
      "sequence" => 1,
      "total_cycles" => 1,
      "frequency" => %{"interval_unit" => "DAY", "interval_count" => days}
    }

    [trial, Map.put(regular, "sequence", 2)]
  end

  @doc """
  The body of `POST /v1/billing/subscriptions`: the plan, the quantity, the reference as
  `custom_id`, the buyer's email when known, and the return and cancel URLs.
  """
  @spec subscription_params(String.t(), Price.t(), Checkout.t()) :: map()
  def subscription_params(plan_id, %Price{quantity: quantity}, %Checkout{} = checkout) do
    %{
      "plan_id" => plan_id,
      "quantity" => Integer.to_string(quantity || 1),
      "custom_id" => custom_id(checkout),
      "application_context" => %{
        "return_url" => without_session(checkout.success_url),
        "cancel_url" => without_session(checkout.cancel_url),
        "user_action" => "SUBSCRIBE_NOW",
        "shipping_preference" => "NO_SHIPPING"
      }
    }
    |> Map.merge(subscriber(checkout.customer))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp subscriber(%{email: email}) when is_binary(email),
    do: %{"subscriber" => %{"email_address" => email}}

  defp subscriber(_none), do: %{}

  @doc """
  A subscription made or read back, as its checkout: the buyer approves it on PayPal's page and
  comes back with its id in `subscription_id`; once approved the checkout is complete and names it.
  """
  @spec subscription_checkout(map(), Checkout.t() | nil) :: Checkout.t()
  def subscription_checkout(sub, checkout \\ nil) do
    status = sub_checkout_status(sub)

    %{
      (checkout ||
         struct(Checkout,
           provider: "paypal",
           mode: :subscription,
           items: [],
           reference: reference(sub["custom_id"]),
           owner: owner(sub["custom_id"]),
           customer: buyer(get_in(sub, ["subscriber", "email_address"]))
         ))
      | id: sub["id"],
        url: link(sub, ["approve"]),
        status: status,
        subscription_id: if(status == :complete, do: sub["id"])
    }
  end

  defp sub_checkout_status(%{"status" => "APPROVAL_PENDING"}), do: :open

  defp sub_checkout_status(%{"status" => status} = sub) when status in ["CANCELLED", "EXPIRED"],
    do: if(Map.has_key?(sub, "billing_info"), do: :complete, else: :expired)

  defp sub_checkout_status(_approved), do: :complete

  @doc """
  A subscription read with its plan (`?fields=plan`) as a `MishkaPay.Subscription`: its one price
  from the plan's regular cycle, the period from its last and next bill, and `:trialing` while
  the plan's trial runs.
  """
  @spec subscription(map()) :: {:ok, Subscription.t()} | {:error, Splode.Error.t()}
  def subscription(sub) do
    billing = sub["billing_info"] || %{}
    status = sub_status(sub, billing)
    subscriber = sub["subscriber"] || %{}

    %{
      provider: "paypal",
      id: sub["id"],
      status: status,
      items: plan_items(sub),
      customer_id: subscriber["payer_id"],
      customer_email: subscriber["email_address"],
      customer_name: name(subscriber["name"]),
      current_period_start: time(get_in(billing, ["last_payment", "time"]) || sub["start_time"]),
      current_period_end: time(billing["next_billing_time"]),
      canceled_at: if(status == :canceled, do: time(sub["status_update_time"])),
      trial_end: if(status == :trialing, do: time(billing["next_billing_time"])),
      reference: reference(sub["custom_id"]),
      owner: owner(sub["custom_id"]),
      created_at: time(sub["create_time"])
    }
    |> Subscription.builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp sub_status(%{"status" => "ACTIVE"}, billing) do
    executions = billing["cycle_executions"] || []

    case {cycle(executions, "TRIAL"), cycle(executions, "REGULAR")} do
      {%{}, %{"cycles_completed" => 0}} -> :trialing
      _paying -> :active
    end
  end

  defp sub_status(%{"status" => status}, _billing), do: Map.get(@subscription_statuses, status)

  defp cycle(cycles, tenure), do: Enum.find(cycles, &(&1["tenure_type"] == tenure))

  defp plan_items(%{"plan" => %{"billing_cycles" => cycles} = plan} = sub) do
    with %{"frequency" => frequency} = regular <- cycle(cycles, "REGULAR"),
         %Elixir.Money{} = amount <- money_of(get_in(regular, ["pricing_scheme", "fixed_price"])) do
      [
        %{
          provider: "paypal",
          id: sub["plan_id"],
          product_id: plan["product_id"],
          name: plan["name"],
          amount: amount,
          quantity: quantity(sub["quantity"]),
          interval: Map.get(@intervals, frequency["interval_unit"]),
          interval_count: frequency["interval_count"]
        }
      ]
    else
      _no_price -> []
    end
  end

  defp plan_items(_no_plan), do: []

  defp quantity(text) when is_binary(text) do
    case Integer.parse(text) do
      {count, ""} when count > 0 -> count
      _other -> 1
    end
  end

  defp quantity(_none), do: 1

  @doc """
  One of a subscription's transactions (`GET /v1/billing/subscriptions/{id}/transactions`) as a
  `MishkaPay.Invoice`: what one bill took, when.
  """
  @spec invoice(map(), String.t()) :: {:ok, Invoice.t()} | {:error, Splode.Error.t()}
  def invoice(transaction, subscription_id) do
    gross = money_of(get_in(transaction, ["amount_with_breakdown", "gross_amount"]))
    status = Map.get(@transaction_statuses, transaction["status"])

    %{
      provider: "paypal",
      id: transaction["id"],
      subscription_id: subscription_id,
      status: status,
      total: gross,
      amount_due: gross,
      amount_paid: if(status == :paid, do: gross),
      created_at: time(transaction["time"])
    }
    |> Invoice.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc """
  The next bill of an active subscription read with its plan: the plan's price for each one of
  its quantity, on its next billing time. Nil when PayPal will not bill it again.
  """
  @spec upcoming_invoice(map()) :: {:ok, Invoice.t()} | {:error, Splode.Error.t()} | nil
  def upcoming_invoice(sub) do
    with next when is_binary(next) <- get_in(sub, ["billing_info", "next_billing_time"]),
         true <- sub["status"] == "ACTIVE",
         [%{amount: amount, quantity: quantity}] <- plan_items(sub) do
      due = Elixir.Money.mult!(amount, quantity)

      %{
        provider: "paypal",
        id: "upcoming-" <> sub["id"],
        subscription_id: sub["id"],
        status: :draft,
        total: due,
        amount_due: due,
        customer_id: get_in(sub, ["subscriber", "payer_id"]),
        period_start: time(next),
        created_at: time(next)
      }
      |> Invoice.builder()
      |> MishkaPay.Errors.from_builder()
    else
      _not_billed_again -> nil
    end
  end

  @doc """
  A PayPal webhook event as a `MishkaPay.Event`, naming the Order it concerns (the Order itself,
  or the Order a capture or refund belongs to) or the subscription. `live?` says whose keys checked it.
  """
  @spec event(map(), boolean()) :: {:ok, Event.t()} | {:error, Splode.Error.t()}
  def event(event, live?) do
    resource = event["resource"] || %{}

    %{
      provider: "paypal",
      id: event["id"],
      type: event["event_type"],
      object_id: resource["id"] || resource["dispute_id"],
      object_type: event["resource_type"],
      payment_id: order_of(event["resource_type"], resource),
      subscription_id: subscription_of(event["resource_type"], resource),
      livemode: live?,
      created_at: time(event["create_time"])
    }
    |> Event.builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp order_of("checkout-order", %{"id" => id}), do: id
  defp order_of(type, _resource) when type in ["subscription", "sale", "dispute"], do: nil

  defp order_of(_capture_or_refund, resource),
    do: get_in(resource, ["supplementary_data", "related_ids", "order_id"])

  # A subscription's own events name it; a renewal's sale names it as its billing agreement.
  defp subscription_of("subscription", %{"id" => id}), do: id
  defp subscription_of("sale", %{"billing_agreement_id" => id}), do: id
  defp subscription_of(_other, _resource), do: nil

  @doc """
  A return URL without Stripe's `{CHECKOUT_SESSION_ID}` placeholder (and the parameter that holds
  it), so one URL serves both providers: PayPal adds its own `token` (or `subscription_id`), which
  `MishkaPay.return_checkout_id/2` reads.
  """
  @spec without_session(String.t() | nil) :: String.t() | nil
  def without_session(nil), do: nil

  def without_session(url) do
    case String.contains?(url, "{CHECKOUT_SESSION_ID}") do
      true -> url |> URI.parse() |> without_placeholder()
      false -> url
    end
  end

  defp without_placeholder(uri) do
    query =
      (uri.query || "")
      |> URI.query_decoder()
      |> Enum.reject(fn {_name, value} -> value == "{CHECKOUT_SESSION_ID}" end)

    case query do
      [] -> URI.to_string(%{uri | query: nil})
      kept -> URI.to_string(%{uri | query: URI.encode_query(kept)})
    end
  end

  @doc """
  PayPal keeps one caller field, `custom_id` (127 characters at most): the reference alone, or,
  when the checkout names its owner, both as `r=<reference>&o=<owner>`, read back by
  `reference/1` and `owner/1`. Nil when the checkout has neither.
  """
  @spec custom_id(Checkout.t()) :: String.t() | nil
  def custom_id(%Checkout{owner: nil, reference: reference}), do: reference

  def custom_id(%Checkout{owner: owner, reference: reference}),
    do: URI.encode_query([{"r", reference || ""}, {"o", owner}])

  @doc "The reference in a `custom_id/1`."
  @spec reference(String.t() | nil) :: String.t() | nil
  def reference(custom_id) do
    case ids(custom_id) do
      {reference, _owner} -> reference
      nil -> custom_id
    end
  end

  @doc "The owner in a `custom_id/1`, nil when the checkout named none."
  @spec owner(String.t() | nil) :: String.t() | nil
  def owner(custom_id) do
    case ids(custom_id) do
      {_reference, owner} -> owner
      nil -> nil
    end
  end

  defp ids("r=" <> _rest = custom_id) do
    case URI.decode_query(custom_id) do
      %{"r" => reference, "o" => owner} = pairs when map_size(pairs) == 2 and owner != "" ->
        {blank_nil(reference), owner}

      _not_ours ->
        nil
    end
  end

  defp ids(_reference_or_nil), do: nil

  defp blank_nil(""), do: nil
  defp blank_nil(text), do: text

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

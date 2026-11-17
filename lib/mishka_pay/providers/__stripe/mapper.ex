# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.Stripe.Mapper do
  @moduledoc """
  The only place that knows Stripe's field names: Mishka Pay's structs become Stripe's params, and
  Stripe's JSON objects (API version `2026-10-28.endive`) become Mishka Pay's structs.
  """

  alias MishkaPay.{
    Address,
    Checkout,
    Coupon,
    CreditNote,
    CreditNoteLine,
    Customer,
    Event,
    Invoice,
    InvoiceItem,
    Money,
    Payment,
    PaymentLink,
    PaymentMethod,
    PortalConfiguration,
    Price,
    Product,
    PromotionCode,
    Refund,
    ShippingRate,
    Subscription,
    SubscriptionPhase,
    SubscriptionSchedule,
    TaxCalculation,
    TaxId,
    TaxLine,
    TaxTransaction
  }

  @reference "mishka_pay_reference"
  @owner "mishka_pay_owner"

  # Where Stripe counts a currency in other places than ISO 4217: ISK and UGX as two-decimal
  # amounts ending in 00, MGA as zero-decimal (docs.stripe.com/currencies).
  @digits %{ISK: 2, UGX: 2, MGA: 0}

  @doc """
  The decimal places Stripe counts `currency` in when they differ from ISO 4217 (ISK and UGX: 2,
  MGA: 0), or `nil` for the ISO ones.
  """
  @spec digits(atom()) :: non_neg_integer() | nil
  def digits(currency), do: Map.get(@digits, currency)

  @doc "Stripe's integer `amount` for `money`, in the places Stripe counts its currency in."
  @spec minor(Elixir.Money.t()) :: integer()
  def minor(%{currency: currency} = money) do
    case digits(currency) do
      nil -> Money.to_minor(money)
      digits -> Money.to_minor(money, digits)
    end
  end

  # Money from Stripe's integer amount, read in the places Stripe counts the currency in. Stripe
  # names currencies in lower case.
  defp from_stripe(minor, currency) when is_integer(minor) and is_binary(currency) do
    case Enum.find(@digits, fn {code, _digits} ->
           Atom.to_string(code) == String.upcase(currency)
         end) do
      nil -> Money.from_minor(minor, currency)
      {_code, digits} -> Money.from_minor(minor, currency, digits)
    end
  end

  defp from_stripe(minor, currency), do: Money.from_minor(minor, currency)

  @checkout_statuses %{"open" => :open, "complete" => :complete, "expired" => :expired}
  @ui_modes %{"hosted_page" => :hosted, "embedded_page" => :embedded}

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
  Params of `POST /v1/checkout/sessions`: a one-time payment, a subscription with its trial, or
  a setup that saves a payment method. The reference and the owner go on the payment, the
  subscription or the setup too, so they come back on each.
  """
  @spec checkout_params(Checkout.t(), map()) :: map()
  def checkout_params(%Checkout{} = checkout, settings \\ %{}) do
    reference =
      Map.reject(%{@reference => checkout.reference, @owner => checkout.owner}, fn {_key, value} ->
        is_nil(value)
      end)

    %{
      "mode" => Atom.to_string(checkout.mode),
      "client_reference_id" => checkout.reference,
      "metadata" => Map.merge(checkout.metadata || %{}, reference)
    }
    |> Map.merge(ui_params(checkout))
    |> Map.merge(mode_data(checkout, reference))
    |> Map.merge(buyer_params(checkout.customer))
    |> Map.merge(options(checkout))
    |> Map.merge(shipping(checkout))
    |> Map.merge(sale_params(checkout, settings))
  end

  # A setup sells nothing: no items or tax, only the currency that picks the payment methods
  # offered. Managed Payments takes no setup mode, so it is off even on an account where it is on
  # by default. Without a known customer Stripe makes one, so the card is kept.
  defp sale_params(%Checkout{mode: :setup} = checkout, _settings) do
    %{"currency" => checkout.currency |> Atom.to_string() |> String.downcase()}
    |> Map.merge(managed_payments(false))
    |> Map.merge(setup_customer(checkout))
  end

  defp sale_params(checkout, settings) do
    %{"line_items" => Enum.map(checkout.items, &line_item/1)}
    |> Map.merge(managed_payments(merchant_of_record(checkout, settings)))
    |> Map.merge(automatic_tax(checkout, settings))
  end

  defp setup_customer(%Checkout{customer: %{id: id}}) when is_binary(id), do: %{}

  defp setup_customer(%Checkout{customer_creation: nil}),
    do: %{"customer_creation" => "always"}

  defp setup_customer(_chosen), do: %{}
  # A hosted page sends the buyer back to one of two pages; an embedded form to its return page.
  defp ui_params(%Checkout{ui_mode: :embedded} = checkout),
    do: %{"ui_mode" => "embedded_page", "return_url" => checkout.return_url}

  defp ui_params(checkout),
    do: %{"success_url" => checkout.success_url, "cancel_url" => checkout.cancel_url}

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
      "invoice_creation" => enabled(checkout.invoice),
      "consent_collection" => checkout.terms && %{"terms_of_service" => "required"},
      "phone_number_collection" => enabled(checkout.phone),
      "custom_fields" => custom_fields(checkout.fields),
      "submit_type" => checkout.submit_type && Atom.to_string(checkout.submit_type),
      "payment_method_collection" => (checkout.card_required == false && "if_required") || nil
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Where the checkout ships, and the rates the buyer picks from; each only when it is set.
  defp shipping(%Checkout{} = checkout) do
    reject_nil(%{
      "shipping_address_collection" =>
        checkout.shipping_countries && %{"allowed_countries" => checkout.shipping_countries},
      "shipping_options" =>
        checkout.shipping_rates && Enum.map(checkout.shipping_rates, &shipping_option/1)
    })
  end

  # A rate Stripe keeps, by its id, or a new one made with the session.
  defp shipping_option(%ShippingRate{id: id}) when is_binary(id), do: %{"shipping_rate" => id}
  defp shipping_option(rate), do: %{"shipping_rate_data" => shipping_rate_params(rate)}

  @doc """
  Params of `POST /v1/shipping_rates` (and of a checkout's `shipping_rate_data`): a fixed amount
  for the order, with its delivery estimate in business days.
  """
  @spec shipping_rate_params(ShippingRate.t()) :: map()
  def shipping_rate_params(%ShippingRate{} = rate) do
    reject_nil(%{
      "display_name" => rate.name,
      "type" => "fixed_amount",
      "fixed_amount" => %{
        "amount" => minor(rate.amount),
        "currency" => lower_currency(rate.amount)
      },
      "delivery_estimate" => delivery_estimate(rate),
      "tax_code" => rate.tax_code,
      "tax_behavior" => rate.tax_behavior && Atom.to_string(rate.tax_behavior),
      "metadata" => rate.metadata
    })
  end

  defp delivery_estimate(%{min_days: nil, max_days: nil}), do: nil

  defp delivery_estimate(rate) do
    reject_nil(%{
      "minimum" => rate.min_days && %{"unit" => "business_day", "value" => rate.min_days},
      "maximum" => rate.max_days && %{"unit" => "business_day", "value" => rate.max_days}
    })
  end

  @doc "A Stripe shipping rate as a `MishkaPay.ShippingRate`."
  @spec shipping_rate(map()) :: {:ok, ShippingRate.t()} | {:error, Splode.Error.t()}
  def shipping_rate(rate) do
    fixed = rate["fixed_amount"] || %{}
    estimate = rate["delivery_estimate"] || %{}

    %{
      provider: "stripe",
      id: rate["id"],
      name: rate["display_name"],
      amount: money(fixed["amount"], fixed["currency"]),
      min_days: days(estimate["minimum"]),
      max_days: days(estimate["maximum"]),
      tax_code: id_of(rate["tax_code"]),
      tax_behavior: tax_behavior(rate["tax_behavior"]),
      active: rate["active"],
      metadata: rate["metadata"],
      created_at: time(rate["created"])
    }
    |> ShippingRate.builder()
    |> MishkaPay.Errors.from_builder()
  end

  # An estimate in days or business days; Stripe's hours, weeks and months have no such field.
  defp days(%{"unit" => unit, "value" => value}) when unit in ["business_day", "day"],
    do: value

  defp days(_other), do: nil

  defp discounts(nil), do: nil
  defp discounts([]), do: nil
  defp discounts(discounts), do: Enum.map(discounts, &discount/1)

  defp discount(%{coupon_id: id}) when is_binary(id), do: %{"coupon" => id}
  defp discount(%{promotion_code_id: id}), do: %{"promotion_code" => id}

  defp enabled(nil), do: nil
  defp enabled(on?), do: %{"enabled" => on?}

  defp mode_data(%Checkout{mode: :subscription, trial_days: days} = checkout, reference),
    do: %{
      "subscription_data" =>
        %{
          "metadata" => reference,
          "trial_period_days" => days,
          "description" => checkout.description,
          "application_fee_percent" =>
            checkout.application_fee_percent &&
              Decimal.to_string(checkout.application_fee_percent, :normal)
        }
        |> Map.merge(seller(checkout))
        |> reject_nil()
    }

  defp mode_data(%Checkout{mode: :setup} = checkout, reference),
    do: %{
      "setup_intent_data" =>
        reject_nil(%{"metadata" => reference, "description" => checkout.description})
    }

  defp mode_data(checkout, reference),
    do: %{
      "payment_intent_data" =>
        %{
          "metadata" => reference,
          "description" => checkout.description,
          "statement_descriptor_suffix" => checkout.statement_suffix,
          "capture_method" => checkout.capture && Atom.to_string(checkout.capture),
          "application_fee_amount" => minor_of(checkout.application_fee)
        }
        |> Map.merge(seller(checkout))
        |> reject_nil()
    }

  # The seller a platform's sale is for: where the money goes, and who sells it.
  defp seller(checkout),
    do: %{
      "transfer_data" => checkout.destination && %{"destination" => checkout.destination},
      "on_behalf_of" => checkout.on_behalf_of
    }

  defp reject_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp custom_fields(nil), do: nil
  defp custom_fields([]), do: nil

  defp custom_fields(fields) do
    for field <- fields do
      reject_nil(%{
        "key" => field.key,
        "label" => %{"type" => "custom", "custom" => field.label},
        "type" => Atom.to_string(field.type),
        "optional" => field.optional,
        "dropdown" =>
          (field.type == :dropdown &&
             %{
               "options" =>
                 Enum.map(
                   field.options,
                   &%{"value" => opt(&1, :value), "label" => opt(&1, :label)}
                 )
             }) ||
            nil
      })
    end
  end

  defp opt(option, name), do: Map.get(option, name) || Map.get(option, Atom.to_string(name))

  # The buyer's answers: each field's key to its value, whatever its type.
  defp field_values(fields) when is_list(fields) do
    Map.new(fields, fn field ->
      value =
        get_in(field, ["text", "value"]) || get_in(field, ["numeric", "value"]) ||
          get_in(field, ["dropdown", "value"])

      {field["key"], value}
    end)
  end

  defp field_values(_none), do: nil

  @doc """
  Whether a checkout sells with Stripe as the merchant of record: its own choice, else the
  tenant's setting, else `nil`, the Stripe account's default.
  """
  @spec merchant_of_record(Checkout.t() | PaymentLink.t(), map()) :: boolean() | nil
  def merchant_of_record(%{merchant_of_record: choice}, _settings)
      when is_boolean(choice),
      do: choice

  def merchant_of_record(_checkout, settings), do: Map.get(settings, :merchant_of_record)

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
          "unit_amount" => minor(amount),
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

  @doc "The `flow_data` of a portal session: the one task it opens on, then back to the site."
  @spec portal_flow(MishkaPay.PortalSession.t()) :: map() | nil
  def portal_flow(%{flow: nil}), do: nil

  def portal_flow(%{flow: flow} = session) do
    type = Atom.to_string(flow)

    %{
      "type" => type,
      "after_completion" => %{
        "type" => "redirect",
        "redirect" => %{"return_url" => session.return_url}
      }
    }
    |> Map.merge(flow_target(flow, session.subscription_id))
  end

  defp flow_target(:payment_method_update, _subscription_id), do: %{}

  defp flow_target(flow, subscription_id),
    do: %{Atom.to_string(flow) => %{"subscription" => subscription_id}}

  @doc """
  Params of `POST /v1/billing_portal/configurations` (and its update): only what is set. A list
  of choices turns its feature on with them, or off when empty.
  """
  @spec portal_configuration_params(PortalConfiguration.t()) :: map()
  def portal_configuration_params(%PortalConfiguration{} = config) do
    %{
      "name" => config.name,
      "active" => config.active,
      "default_return_url" => config.default_return_url,
      "metadata" => config.metadata,
      "business_profile" => %{
        "headline" => config.headline,
        "privacy_policy_url" => config.privacy_policy_url,
        "terms_of_service_url" => config.terms_of_service_url
      },
      "features" => %{
        "invoice_history" => enabled(config.invoice_history),
        "payment_method_update" => enabled(config.payment_method_update),
        "customer_update" => allowed(config.customer_update, "allowed_updates"),
        "subscription_cancel" => portal_cancel(config.subscription_cancel),
        "subscription_update" =>
          config.subscription_update
          |> allowed("default_allowed_updates")
          |> Kernel.||(%{})
          |> Map.merge(%{
            "products" => config.plans && Enum.map(config.plans, &portal_plan/1),
            "proration_behavior" => config.proration && Atom.to_string(config.proration)
          })
      }
    }
  end

  defp allowed(nil, _key), do: nil

  defp allowed(choices, key),
    do: %{"enabled" => choices != [], key => Enum.map(choices, &Atom.to_string/1)}

  defp portal_cancel(nil), do: nil
  defp portal_cancel(:off), do: %{"enabled" => false}
  defp portal_cancel(mode), do: %{"enabled" => true, "mode" => Atom.to_string(mode)}

  defp portal_plan(plan), do: %{"product" => plan.product_id, "prices" => plan.price_ids}

  @doc "A Stripe portal configuration (`billing_portal.configuration`) as a `MishkaPay.PortalConfiguration`."
  @spec portal_configuration(map()) ::
          {:ok, PortalConfiguration.t()} | {:error, Splode.Error.t()}
  def portal_configuration(config) do
    features = config["features"] || %{}
    profile = config["business_profile"] || %{}
    update = features["subscription_update"] || %{}
    cancel = features["subscription_cancel"] || %{}

    %{
      provider: "stripe",
      id: config["id"],
      name: config["name"],
      active: config["active"] == true,
      default: config["is_default"] == true,
      headline: profile["headline"],
      privacy_policy_url: profile["privacy_policy_url"],
      terms_of_service_url: profile["terms_of_service_url"],
      default_return_url: config["default_return_url"],
      invoice_history: get_in(features, ["invoice_history", "enabled"]) == true,
      payment_method_update: get_in(features, ["payment_method_update", "enabled"]) == true,
      customer_update: turned_on(features["customer_update"], "allowed_updates"),
      subscription_cancel: (cancel["enabled"] == true && cancel["mode"]) || "off",
      subscription_update: turned_on(update, "default_allowed_updates"),
      plans:
        Enum.map(update["products"] || [], &%{product_id: &1["product"], price_ids: &1["prices"]}),
      proration: update["proration_behavior"],
      metadata: config["metadata"] || %{},
      created_at: time(config["created"])
    }
    |> Map.reject(fn {_field, value} -> value == "" end)
    |> PortalConfiguration.builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp turned_on(%{"enabled" => true} = feature, key), do: feature[key] || []
  defp turned_on(_off, _key), do: []

  @doc "A Checkout Session read back on its own: what Stripe filled in and the reference."
  @spec checkout(map()) :: Checkout.t()
  def checkout(session) do
    read_back =
      struct(Checkout,
        provider: "stripe",
        items: sold(session["line_items"]),
        reference: session["client_reference_id"],
        customer: buyer(session)
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
        ui_mode: Map.get(@ui_modes, session["ui_mode"], checkout.ui_mode),
        client_secret: session["client_secret"],
        return_url: session["return_url"] || checkout.return_url,
        status: Map.get(@checkout_statuses, session["status"]),
        payment_id: id_of(session["payment_intent"]),
        setup_intent_id: id_of(session["setup_intent"]),
        payment_method_id: id_of(expanded(session["setup_intent"])["payment_method"]),
        subscription_id: id_of(session["subscription"]),
        amount_total: money(session["amount_total"], session["currency"]),
        amount_tax: money(get_in(session, ["total_details", "amount_tax"]), session["currency"]),
        amount_discount:
          money(get_in(session, ["total_details", "amount_discount"]), session["currency"]),
        expires_at: time(session["expires_at"]),
        invoice_id: id_of(session["invoice"]),
        payment_link_id: id_of(session["payment_link"]),
        phone_number: get_in(session, ["customer_details", "phone"]),
        field_values: field_values(session["custom_fields"]),
        terms_accepted:
          (is_map(session["consent"]) && session["consent"]["terms_of_service"] == "accepted") ||
            nil,
        shipping_address: shipping_address(session),
        amount_shipping:
          money(get_in(session, ["total_details", "amount_shipping"]), session["currency"]),
        shipping_rate_id: id_of(get_in(session, ["shipping_cost", "shipping_rate"]))
    }
  end

  # The buyer as Stripe has them after the checkout: the customer it sold to or made, and the
  # email they typed.
  defp buyer(session) do
    case {id_of(session["customer"]), get_in(session, ["customer_details", "email"])} do
      {nil, nil} -> nil
      {id, email} -> struct(MishkaPay.Customer, id: id, email: email)
    end
  end

  # Where the buyer asked it shipped, with the recipient's name.
  defp shipping_address(session) do
    details = get_in(session, ["collected_information", "shipping_details"]) || %{}

    case address(details["address"]) do
      nil -> nil
      address -> struct(Address, Map.put(address, :name, blank(details["name"])))
    end
  end

  defp money(minor, currency) when is_integer(minor) and is_binary(currency) do
    case from_stripe(minor, currency) do
      {:ok, money} -> money
      {:error, _odd} -> nil
    end
  end

  defp money(_minor, _currency), do: nil

  defp signed_money(minor, currency) when is_integer(minor) and is_binary(currency) do
    case from_stripe(abs(minor), currency) do
      {:ok, money} when minor < 0 -> Elixir.Money.negate!(money)
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
    captured = captured(intent)

    with {:ok, amount} <- from_stripe(intent["amount"], intent["currency"]),
         {:ok, refunded} <- from_stripe(charge["amount_refunded"] || 0, intent["currency"]) do
      %{
        provider: "stripe",
        id: intent["id"],
        amount: amount,
        amount_refunded: refunded,
        amount_captured: captured,
        status: payment_status(intent, refunded, captured || amount),
        reference: get_in(intent, ["metadata", @reference]),
        owner: get_in(intent, ["metadata", @owner]),
        description: intent["description"],
        metadata: Map.drop(intent["metadata"] || %{}, [@reference, @owner]),
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
      schedule_id: id_of(sub["schedule"]),
      pause_behavior: get_in(sub, ["pause_collection", "behavior"]),
      resumes_at: time(get_in(sub, ["pause_collection", "resumes_at"])),
      reference: get_in(sub, ["metadata", @reference]),
      owner: get_in(sub, ["metadata", @owner]),
      metadata: Map.drop(sub["metadata"] || %{}, [@reference, @owner]),
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
            product_id: id_of(price["product"]),
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

  @tax_id_checks %{
    "pending" => :pending,
    "verified" => :verified,
    "unverified" => :unverified,
    "unavailable" => :unavailable
  }

  @doc "Params of `POST /v1/customers/:id/tax_ids`: its kind and its number."
  @spec tax_id_params(TaxId.t()) :: map()
  def tax_id_params(%TaxId{} = tax_id), do: %{"type" => tax_id.type, "value" => tax_id.value}

  @doc "A Stripe tax id (`object: \"tax_id\"`) as a `MishkaPay.TaxId`, with its register check."
  @spec tax_id(map()) :: {:ok, TaxId.t()} | {:error, Splode.Error.t()}
  def tax_id(tax_id) do
    check = tax_id["verification"] || %{}

    %{
      provider: "stripe",
      id: tax_id["id"],
      customer_id: id_of(tax_id["customer"]),
      type: tax_id["type"],
      value: tax_id["value"],
      country: tax_id["country"],
      verification: Map.get(@tax_id_checks, check["status"]),
      verified_name: blank(check["verified_name"]),
      verified_address: blank(check["verified_address"]),
      created_at: time(tax_id["created"])
    }
    |> TaxId.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc """
  Params of `POST /v1/tax/calculations`: the lines (each its whole amount), the buyer's address
  or customer, the shipping cost, and the lines asked back with their tax.
  """
  @spec tax_calculation_params(TaxCalculation.t()) :: map()
  def tax_calculation_params(%TaxCalculation{items: [first | _]} = calculation) do
    reject_nil(%{
      "currency" => lower_currency(first.amount),
      "line_items" => Enum.map(calculation.items, &tax_line_params/1),
      "customer" => calculation.customer_id,
      "customer_details" =>
        calculation.address &&
          %{
            "address" => address_params(calculation.address),
            "address_source" => Atom.to_string(calculation.address_source)
          },
      "shipping_cost" => calculation.shipping && %{"amount" => minor(calculation.shipping)},
      "expand" => ["line_items"]
    })
  end

  defp tax_line_params(%TaxLine{} = line) do
    reject_nil(%{
      "reference" => line.reference,
      "amount" => minor(line.amount),
      "quantity" => line.quantity,
      "tax_code" => line.tax_code,
      "tax_behavior" => line.tax_behavior && Atom.to_string(line.tax_behavior),
      "product" => line.product_id
    })
  end

  defp address_params(%Address{} = address) do
    address
    |> Map.take([:country, :postal_code, :line1, :line2, :city, :state])
    |> Map.new(fn {field, value} -> {Atom.to_string(field), value} end)
    |> reject_nil()
  end

  @doc "A Stripe Tax Calculation (`tax.calculation`) as a `MishkaPay.TaxCalculation`."
  @spec tax_calculation(map()) :: {:ok, TaxCalculation.t()} | {:error, Splode.Error.t()}
  def tax_calculation(calculation) do
    currency = calculation["currency"]
    details = calculation["customer_details"] || %{}

    %{
      provider: "stripe",
      id: calculation["id"],
      items:
        calculation
        |> get_in(["line_items", "data"])
        |> List.wrap()
        |> Enum.map(&tax_line(&1, currency)),
      customer_id: id_of(calculation["customer"]),
      address: address(details["address"]),
      address_source: details["address_source"],
      shipping: money(get_in(calculation, ["shipping_cost", "amount"]), currency),
      amount_total: money(calculation["amount_total"], currency),
      tax_amount_exclusive: money(calculation["tax_amount_exclusive"], currency),
      tax_amount_inclusive: money(calculation["tax_amount_inclusive"], currency),
      expires_at: time(calculation["expires_at"])
    }
    |> reject_nil()
    |> TaxCalculation.builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp tax_line(line, currency) do
    reject_nil(%{
      id: line["id"],
      reference: line["reference"],
      amount: money(line["amount"], currency),
      quantity: line["quantity"],
      tax_code: id_of(line["tax_code"]),
      tax_behavior: tax_behavior(line["tax_behavior"]),
      product_id: id_of(line["product"]),
      amount_tax: money(line["amount_tax"], currency)
    })
  end

  # A Stripe address, its empty fields left out; none without a country.
  defp address(%{"country" => country} = address) when is_binary(country) do
    address
    |> Map.take(~w(country postal_code line1 line2 city state))
    |> Map.new(fn {field, value} -> {String.to_existing_atom(field), blank(value)} end)
    |> reject_nil()
  end

  defp address(_none), do: nil

  @doc "A Stripe Tax Transaction as a `MishkaPay.TaxTransaction`, made from `calculation_id`."
  @spec tax_transaction(map(), String.t()) ::
          {:ok, TaxTransaction.t()} | {:error, Splode.Error.t()}
  def tax_transaction(transaction, calculation_id) do
    %{
      provider: "stripe",
      id: transaction["id"],
      reference: transaction["reference"],
      calculation_id: calculation_id,
      customer_id: id_of(transaction["customer"]),
      posted_at: time(transaction["posted_at"]),
      created_at: time(transaction["created"])
    }
    |> TaxTransaction.builder()
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
      payment_id: id_of(invoice["payment_intent"]) || paid_by(invoice),
      number: invoice["number"],
      collection: known(invoice["collection_method"], ~w(charge_automatically send_invoice)),
      due_at: time(invoice["due_date"]),
      description: invoice["description"],
      reference: get_in(invoice, ["metadata", @reference]),
      created_at: time(invoice["created"])
    }
    |> Invoice.builder()
    |> MishkaPay.Errors.from_builder()
  end

  # In this API version an invoice names what paid it in its payments list.
  defp paid_by(%{"payments" => %{"data" => [_ | _] = payments}}) do
    Enum.find_value(payments, &id_of(get_in(&1, ["payment", "payment_intent"])))
  end

  defp paid_by(_invoice), do: nil

  @doc """
  Params of `POST /v1/invoices` for a draft: its customer, how it is collected, and the reference
  in its metadata. Its items are added after, each on its own (`invoice_item_params/3`).
  """
  @spec invoice_params(MishkaPay.InvoiceDraft.t()) :: map()
  def invoice_params(draft) do
    %{
      "customer" => draft.customer_id,
      "collection_method" => Atom.to_string(draft.collection),
      "days_until_due" =>
        (draft.collection == :send_invoice && (draft.days_until_due || 30)) || nil,
      "description" => draft.description,
      "footer" => draft.footer,
      "auto_advance" => false,
      "pending_invoice_items_behavior" => "exclude",
      "currency" => draft_currency(draft.items),
      "metadata" =>
        Map.merge(
          draft.metadata || %{},
          (draft.reference && %{@reference => draft.reference}) || %{}
        )
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp draft_currency(items) do
    Enum.find_value(items, fn
      %Price{amount: %{currency: currency}} -> currency |> to_string() |> String.downcase()
      _catalog -> nil
    end)
  end

  @doc """
  Params of `POST /v1/invoiceitems` for one item of a draft, on `invoice_id`, or for one kept on
  its own (`invoice_id` nil: it waits for the customer's next bill).
  """
  @spec invoice_item_params(Price.t(), String.t() | nil, String.t()) :: map()
  def invoice_item_params(%Price{} = price, invoice_id, customer_id) do
    price
    |> charge_params()
    |> Map.merge(%{"invoice" => invoice_id, "customer" => customer_id})
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  Params of `POST /v1/invoiceitems` for a `MishkaPay.InvoiceItem` made on its own: the line a
  draft's item sends (`invoice_item_params/3`), with the reference in its metadata.
  """
  @spec invoice_item_params(InvoiceItem.t()) :: map()
  def invoice_item_params(%InvoiceItem{} = item) do
    item
    |> InvoiceItem.price()
    |> invoice_item_params(item.invoice_id, item.customer_id)
    |> Map.merge(item_metadata(item))
  end

  @doc """
  Params of `POST /v1/invoiceitems/:id`: only what the change sets. Stripe keeps the item's
  currency, so the amount is sent in its places without one.
  """
  @spec invoice_item_update_params(InvoiceItem.t()) :: map()
  def invoice_item_update_params(%InvoiceItem{} = item) do
    item
    |> InvoiceItem.price()
    |> charge_params()
    |> Map.delete("currency")
    |> Map.merge(item_metadata(item))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # What one line charges: a catalog price by id, or a name with the price of one.
  defp charge_params(%Price{id: id, quantity: quantity}) when is_binary(id),
    do: %{"pricing" => %{"price" => id}, "quantity" => quantity}

  defp charge_params(%Price{amount: amount} = price) do
    %{
      "description" => price.name,
      "currency" => amount && amount.currency |> to_string() |> String.downcase(),
      "unit_amount_decimal" => amount && amount |> minor() |> Integer.to_string(),
      "quantity" => price.quantity,
      "tax_code" => price.tax_code,
      "tax_behavior" => price.tax_behavior && Atom.to_string(price.tax_behavior)
    }
  end

  defp item_metadata(%InvoiceItem{} = item) do
    case with_reference(item.metadata, item.reference) do
      nil -> %{}
      metadata -> %{"metadata" => metadata}
    end
  end

  @doc "A Stripe invoice item (`object: \"invoiceitem\"`) as a `MishkaPay.InvoiceItem`."
  @spec invoice_item(map()) :: {:ok, InvoiceItem.t()} | {:error, Splode.Error.t()}
  def invoice_item(item) do
    currency = item["currency"]

    %{
      provider: "stripe",
      id: item["id"],
      customer_id: id_of(item["customer"]),
      invoice_id: id_of(item["invoice"]),
      price_id: id_of(get_in(item, ["pricing", "price_details", "price"])),
      name: blank(item["description"]),
      amount: unit_money(get_in(item, ["pricing", "unit_amount_decimal"]), currency),
      quantity: item["quantity"],
      total: signed_money(item["amount"], currency),
      period_start: time(get_in(item, ["period", "start"])),
      period_end: time(get_in(item, ["period", "end"])),
      reference: get_in(item, ["metadata", @reference]),
      metadata: Map.delete(item["metadata"] || %{}, @reference),
      created_at: time(item["date"])
    }
    |> InvoiceItem.builder()
    |> MishkaPay.Errors.from_builder()
  end

  # Stripe gives the price of one as a decimal string of its smallest units; a fraction of one
  # unit is not kept.
  defp unit_money(decimal, currency) when is_binary(decimal) do
    case Integer.parse(decimal) do
      {minor, ""} -> signed_money(minor, currency)
      _fraction -> nil
    end
  end

  defp unit_money(_none, _currency), do: nil

  @doc """
  Params of `POST /v1/subscription_schedules`: `from_subscription` alone (Stripe takes nothing
  else with it, metadata neither), or the customer, its start (now unless given), the phases and
  what happens after them, with the reference in its metadata.
  """
  @spec subscription_schedule_params(SubscriptionSchedule.t()) :: map()
  def subscription_schedule_params(%SubscriptionSchedule{subscription_id: id})
      when is_binary(id),
      do: %{"from_subscription" => id}

  def subscription_schedule_params(%SubscriptionSchedule{} = schedule) do
    reject_nil(%{
      "customer" => schedule.customer_id,
      "start_date" => unix(schedule.start_at) || "now",
      "end_behavior" => schedule.end_behavior && Atom.to_string(schedule.end_behavior),
      "phases" => Enum.map(schedule.phases, &phase_params/1),
      "metadata" => schedule_metadata(schedule)
    })
  end

  @doc "Params of `POST /v1/subscription_schedules/:id`: only what the change sets."
  @spec subscription_schedule_update_params(SubscriptionSchedule.t()) :: map()
  def subscription_schedule_update_params(%SubscriptionSchedule{} = schedule) do
    reject_nil(%{
      "end_behavior" => schedule.end_behavior && Atom.to_string(schedule.end_behavior),
      "phases" => schedule.phases && Enum.map(schedule.phases, &phase_params/1),
      "proration_behavior" => schedule.proration && Atom.to_string(schedule.proration),
      "metadata" => schedule_metadata(schedule)
    })
  end

  defp schedule_metadata(schedule), do: with_reference(schedule.metadata, schedule.reference)

  # This API version takes a phase's length as a `duration`; `iterations` is gone.
  defp phase_params(%SubscriptionPhase{} = phase) do
    reject_nil(%{
      "items" =>
        Enum.map(phase.items, &reject_nil(%{"price" => &1.id, "quantity" => &1.quantity})),
      "start_date" => unix(phase.start_at),
      "end_date" => unix(phase.end_at),
      "duration" =>
        phase.iterations &&
          %{"interval" => Atom.to_string(phase.interval), "interval_count" => phase.iterations},
      "trial" => (phase.trial == true && true) || nil,
      "trial_end" => unix(phase.trial_end_at),
      "proration_behavior" => phase.proration && Atom.to_string(phase.proration)
    })
  end

  defp unix(nil), do: nil
  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)

  @doc """
  A Stripe subscription schedule as a `MishkaPay.SubscriptionSchedule`: its phases with their
  dates, and which of them runs now.
  """
  @spec subscription_schedule(map()) ::
          {:ok, SubscriptionSchedule.t()} | {:error, Splode.Error.t()}
  def subscription_schedule(schedule) do
    phases = schedule["phases"] |> List.wrap() |> Enum.map(&phase/1)
    current = get_in(schedule, ["current_phase", "start_date"])

    %{
      provider: "stripe",
      id: schedule["id"],
      customer_id: id_of(schedule["customer"]),
      subscription_id: id_of(schedule["subscription"]),
      released_subscription_id: id_of(schedule["released_subscription"]),
      status: known(schedule["status"], ~w(not_started active completed released canceled)),
      end_behavior: known(schedule["end_behavior"], ~w(release cancel)),
      phases: phases,
      current_phase: current && Enum.find_index(phases, &(&1.start_at == time(current))),
      reference: get_in(schedule, ["metadata", @reference]),
      metadata: Map.delete(schedule["metadata"] || %{}, @reference),
      created_at: time(schedule["created"]),
      released_at: time(schedule["released_at"]),
      canceled_at: time(schedule["canceled_at"]),
      completed_at: time(schedule["completed_at"])
    }
    |> SubscriptionSchedule.builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp phase(phase) do
    %{
      items:
        phase["items"]
        |> List.wrap()
        |> Enum.map(&%{id: id_of(&1["price"]), quantity: &1["quantity"]}),
      start_at: time(phase["start_date"]),
      end_at: time(phase["end_date"]),
      trial_end_at: time(phase["trial_end"]),
      proration: known(phase["proration_behavior"], ~w(create_prorations always_invoice none))
    }
  end

  @doc """
  Params of `POST /v1/credit_notes` (and of its preview): the bill, the amount or the lines, where
  the money goes, and the reference in its metadata.
  """
  @spec credit_note_params(CreditNote.t()) :: map()
  def credit_note_params(%CreditNote{} = note) do
    %{
      "invoice" => note.invoice_id,
      "amount" => minor_of(note.amount),
      "lines" => credit_lines_params(note.lines),
      "reason" => note.reason && Atom.to_string(note.reason),
      "refund_amount" => minor_of(note.refund_amount),
      "credit_amount" => minor_of(note.credit_amount),
      "out_of_band_amount" => minor_of(note.out_of_band_amount),
      "memo" => note.memo,
      "metadata" => with_reference(note.metadata, note.reference)
    }
    |> reject_nil()
  end

  defp credit_lines_params(lines) when lines in [nil, []], do: nil
  defp credit_lines_params(lines), do: Enum.map(lines, &credit_line_params/1)

  defp credit_line_params(%CreditNoteLine{invoice_line_id: id} = line) when is_binary(id) do
    %{
      "type" => "invoice_line_item",
      "invoice_line_item" => id,
      "quantity" => line.quantity,
      "amount" => minor_of(line.amount)
    }
    |> reject_nil()
  end

  defp credit_line_params(%CreditNoteLine{} = line) do
    %{
      "type" => "custom_line_item",
      "description" => line.name,
      "quantity" => line.quantity || 1,
      "unit_amount_decimal" => line.unit_amount |> minor() |> Integer.to_string()
    }
  end

  defp minor_of(nil), do: nil
  defp minor_of(money), do: minor(money)

  defp with_reference(metadata, nil) when metadata in [nil, %{}], do: nil
  defp with_reference(metadata, nil), do: metadata
  defp with_reference(metadata, reference), do: Map.put(metadata || %{}, @reference, reference)

  @credit_line_types %{"invoice_line_item" => :invoice_line, "custom_line_item" => :custom}

  @doc "A Stripe credit note (`object: \"credit_note\"`) as a `MishkaPay.CreditNote`, with its lines."
  @spec credit_note(map()) :: {:ok, CreditNote.t()} | {:error, Splode.Error.t()}
  def credit_note(note) do
    currency = note["currency"]

    %{
      provider: "stripe",
      id: note["id"],
      invoice_id: id_of(note["invoice"]),
      customer_id: id_of(note["customer"]),
      amount: money(note["amount"], currency),
      amount_tax: money(tax_of(note), currency),
      lines:
        note
        |> get_in(["lines", "data"])
        |> List.wrap()
        |> Enum.map(&credit_line(&1, currency)),
      reason: known(note["reason"], ~w(duplicate fraudulent order_change product_unsatisfactory)),
      out_of_band_amount: money(note["out_of_band_amount"], currency),
      memo: blank(note["memo"]),
      number: note["number"],
      status: known(note["status"], ~w(issued void)),
      type: known(note["type"], ~w(pre_payment post_payment mixed)),
      refund_ids:
        note["refunds"] |> List.wrap() |> Enum.map(&id_of(&1["refund"])) |> Enum.reject(&is_nil/1),
      pdf_url: note["pdf"],
      reference: get_in(note, ["metadata", @reference]),
      metadata: Map.delete(note["metadata"] || %{}, @reference),
      voided_at: time(note["voided_at"]),
      created_at: time(note["created"])
    }
    |> CreditNote.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc """
  A Stripe credit note line item as a `MishkaPay.CreditNoteLine`, in its note's `currency` (the
  line carries none).
  """
  @spec credit_note_line(map(), String.t()) ::
          {:ok, CreditNoteLine.t()} | {:error, Splode.Error.t()}
  def credit_note_line(line, currency) do
    line
    |> credit_line(currency)
    |> CreditNoteLine.builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp credit_line(line, currency) do
    %{
      id: line["id"],
      type: Map.get(@credit_line_types, line["type"]),
      invoice_line_id: id_of(line["invoice_line_item"]),
      name: blank(line["description"]),
      quantity: line["quantity"],
      unit_amount: unit_money(line["unit_amount_decimal"], currency),
      amount: money(line["amount"], currency)
    }
  end

  # Stripe sums an invoice's taxes in `total_taxes`.
  defp tax_of(%{"total_taxes" => taxes}) when is_list(taxes),
    do: Enum.reduce(taxes, 0, &((&1["amount"] || 0) + &2))

  defp tax_of(_no_taxes), do: nil

  defp line(line, currency) do
    %{
      id: line["id"],
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
  defp payment_status(%{"status" => "requires_capture"}, _refunded, _amount), do: :authorized
  defp payment_status(%{"status" => "canceled"}, _refunded, _amount), do: :canceled

  defp payment_status(
         %{"status" => "requires_payment_method", "last_payment_error" => %{}},
         _r,
         _a
       ),
       do: :failed

  defp payment_status(_waiting, _refunded, _amount), do: :pending

  # What Stripe took on a paid PaymentIntent; less than its amount after a capture in part.
  defp captured(%{"status" => "succeeded", "amount_received" => received} = intent)
       when is_integer(received) and received > 0,
       do: money(received, intent["currency"])

  defp captured(_not_paid), do: nil

  @doc """
  Params of `POST /v1/payment_intents/:id/capture`: the part to take, or none for all that is
  held.
  """
  @spec capture_params(Elixir.Money.t() | nil) :: map()
  def capture_params(nil), do: %{}
  def capture_params(amount), do: %{"amount_to_capture" => minor(amount)}

  @doc "Params of `POST /v1/refunds`: the payment, and the amount when it is not the whole."
  @spec refund_params(Refund.t()) :: map()
  def refund_params(%Refund{} = refund) do
    %{
      "payment_intent" => refund.payment_id,
      "amount" => refund.amount && minor(refund.amount),
      "reason" => refund.reason && Atom.to_string(refund.reason),
      "metadata" => refund.reference && %{@reference => refund.reference}
    }
  end

  @doc """
  A Stripe refund read on its own, as a `MishkaPay.Refund`; its payment is the PaymentIntent, or
  the charge for a refund of a payment made without one.
  """
  @spec refund(map()) :: {:ok, Refund.t()} | {:error, Splode.Error.t()}
  def refund(refund) do
    with {:ok, amount} <- from_stripe(refund["amount"], refund["currency"]) do
      %{
        provider: "stripe",
        payment_id: id_of(refund["payment_intent"]) || id_of(refund["charge"]),
        id: refund["id"],
        amount: amount,
        status: Map.get(@refund_statuses, refund["status"]),
        reason: Map.get(@refund_reasons, refund["reason"]),
        reference: get_in(refund, ["metadata", @reference]),
        created_at: time(refund["created"])
      }
      |> Refund.builder()
      |> MishkaPay.Errors.from_builder()
    end
  end

  @doc "The refund with Stripe's answer: its id, status, amount and time."
  @spec refund(map(), Refund.t()) :: {:ok, Refund.t()} | {:error, Splode.Error.t()}
  def refund(answer, %Refund{} = refund) do
    with {:ok, amount} <- from_stripe(answer["amount"], answer["currency"]) do
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

  @doc """
  A Stripe event (`object: "event"`) as a `MishkaPay.Event`, with what it is about. A saved
  payment method's or a setup's event is about the customer it names (a detached payment method
  names it in `previous_attributes`), since that customer is what changes.
  """
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
      customer_id: customer_of(event, object),
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

  # A schedule runs its subscription, or names the one it let go.
  defp subscription_of(%{"object" => "subscription_schedule"} = schedule),
    do: id_of(schedule["subscription"]) || id_of(schedule["released_subscription"])

  defp subscription_of(%{"parent" => %{"subscription_details" => %{"subscription" => sub}}}),
    do: id_of(sub)

  defp subscription_of(%{"subscription" => sub}), do: id_of(sub)
  defp subscription_of(_other), do: nil

  defp dispute_of(%{"object" => "dispute", "id" => id}) when is_binary(id), do: id
  defp dispute_of(_other), do: nil

  # The customer itself, or the one a tax id belongs to. A payment or a subscription names its
  # customer too, but the event is about them, not about the customer.
  # The customer an event changes: the customer itself, or the one a tax id, a saved payment
  # method, a setup or an entitlement summary belongs to. A detached payment method has lost its
  # customer, and names it in the event's previous attributes.
  defp customer_of(_event, %{"object" => "customer", "id" => id}) when is_binary(id), do: id

  defp customer_of(event, %{"object" => type} = object)
       when type in ~w(tax_id payment_method setup_intent entitlements.active_entitlement_summary) do
    id_of(object["customer"]) || id_of(get_in(event, ["data", "previous_attributes", "customer"]))
  end

  defp customer_of(_event, _other), do: nil

  @dispute_statuses ~w(warning_needs_response warning_under_review warning_closed needs_response under_review won lost prevented)

  @doc "A Stripe PaymentMethod as a `MishkaPay.PaymentMethod`, with its card when it is one."
  @spec payment_method(map()) :: {:ok, PaymentMethod.t()} | {:error, Splode.Error.t()}
  def payment_method(method) do
    card = method["card"] || %{}

    %{
      provider: "stripe",
      id: method["id"],
      customer_id: id_of(method["customer"]),
      type: method["type"],
      card_brand: card["brand"],
      card_last4: card["last4"],
      card_exp_month: card["exp_month"],
      card_exp_year: card["exp_year"],
      created_at: time(method["created"])
    }
    |> PaymentMethod.builder()
    |> MishkaPay.Errors.from_builder()
  end

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

  @doc "A Stripe Radar early fraud warning as a `MishkaPay.FraudWarning`."
  @spec fraud_warning(map()) :: {:ok, MishkaPay.FraudWarning.t()} | {:error, Splode.Error.t()}
  def fraud_warning(warning) do
    %{
      provider: "stripe",
      id: warning["id"],
      payment_id: id_of(warning["payment_intent"]),
      charge_id: id_of(warning["charge"]),
      fraud_type: warning["fraud_type"],
      actionable: warning["actionable"] == true,
      created_at: time(warning["created"])
    }
    |> MishkaPay.FraudWarning.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @opened_reasons %{"rule" => :rule, "manual" => :manual}

  @doc "A Stripe Radar review as a `MishkaPay.FraudReview`."
  @spec fraud_review(map()) :: {:ok, MishkaPay.FraudReview.t()} | {:error, Splode.Error.t()}
  def fraud_review(review) do
    %{
      provider: "stripe",
      id: review["id"],
      payment_id: id_of(review["payment_intent"]),
      charge_id: id_of(review["charge"]),
      open: review["open"] == true,
      opened_reason: Map.get(@opened_reasons, review["opened_reason"]),
      reason: review["reason"],
      closed_reason: review["closed_reason"],
      ip_address: review["ip_address"],
      created_at: time(review["created"])
    }
    |> MishkaPay.FraudReview.builder()
    |> MishkaPay.Errors.from_builder()
  end

  # The dispute evidence fields that take the id of an uploaded file, not text.
  @evidence_files ~w(cancellation_policy customer_communication customer_signature duplicate_charge_documentation receipt refund_policy service_documentation shipping_documentation uncategorized_file)

  @doc "The dispute evidence fields that take a file id (`file_...`) instead of text."
  @spec evidence_files() :: [String.t()]
  def evidence_files, do: @evidence_files

  @doc """
  Params of `POST /v1/files`, as multipart parts: the purpose, and the file with its name and
  content type.
  """
  @spec file_params(MishkaPay.FileUpload.t()) :: [{String.t(), term()}]
  def file_params(%MishkaPay.FileUpload{} = upload) do
    [
      {"purpose", Atom.to_string(upload.purpose)},
      {"file", {upload.content, filename: upload.filename, content_type: upload.content_type}}
    ]
  end

  @doc "A Stripe file as a `MishkaPay.File`."
  @spec file(map()) :: {:ok, MishkaPay.File.t()} | {:error, Splode.Error.t()}
  def file(file) do
    %{
      provider: "stripe",
      id: file["id"],
      purpose: known(file["purpose"], ~w(dispute_evidence)) || :other,
      filename: file["filename"],
      size: file["size"],
      type: file["type"],
      url: file["url"],
      expires_at: time(file["expires_at"]),
      created_at: time(file["created"])
    }
    |> MishkaPay.File.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc "Params of `POST /v1/file_links`: the file, and when the link ends."
  @spec file_link_params(String.t(), keyword()) :: map()
  def file_link_params(file_id, opts) do
    %{"file" => file_id, "expires_at" => opts[:expires_at] && DateTime.to_unix(opts[:expires_at])}
  end

  @doc "A Stripe file link as a `MishkaPay.FileLink`."
  @spec file_link(map()) :: {:ok, MishkaPay.FileLink.t()} | {:error, Splode.Error.t()}
  def file_link(link) do
    %{
      provider: "stripe",
      id: link["id"],
      file_id: id_of(link["file"]),
      url: link["url"],
      expires_at: time(link["expires_at"]),
      expired: link["expired"] == true,
      created_at: time(link["created"])
    }
    |> MishkaPay.FileLink.builder()
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
      "amount_off" => coupon.amount_off && minor(coupon.amount_off),
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
      "minimum_amount" => minimum && minor(minimum),
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
      "unit_amount" => minor(price.amount),
      "nickname" => price.name,
      "lookup_key" => price.lookup_key,
      "tax_behavior" => price.tax_behavior && Atom.to_string(price.tax_behavior),
      "metadata" => price.metadata
    }
    |> Map.merge(recurring(price))
    |> metered(price.meter_id)
  end

  # A price on a meter bills each period's usage the meter counted, not a quantity.
  defp metered(params, nil), do: params

  defp metered(%{"recurring" => recurring} = params, meter_id),
    do: %{
      params
      | "recurring" => Map.merge(recurring, %{"usage_type" => "metered", "meter" => meter_id})
    }

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
      meter_id: get_in(price, ["recurring", "meter"]),
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

  @doc """
  What a checkout sold, from its line items (asked for with `expand[]=line_items`): each a
  `MishkaPay.Price` with its price and product ids, name, unit amount and quantity.
  """
  @spec sold(map() | nil) :: [Price.t()]
  def sold(%{"data" => items}) do
    for %{"price" => %{} = price} = item <- items,
        {:ok, sold} <- [sold_item(item, price)],
        do: sold
  end

  def sold(_not_expanded), do: []

  defp sold_item(item, price) do
    %{
      id: price["id"],
      product_id: id_of(price["product"]),
      name: item["description"],
      amount: money(price["unit_amount"], price["currency"]),
      quantity: item["quantity"] || 1,
      interval: interval(get_in(price, ["recurring", "interval"])),
      interval_count: get_in(price, ["recurring", "interval_count"])
    }
    |> Price.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc "The payment with the checkout that took it and what it sold, from Stripe's list of sessions."
  @spec with_checkout(Payment.t(), map() | nil) :: Payment.t()
  def with_checkout(%Payment{} = payment, %{} = session),
    do: %{payment | checkout_id: session["id"], items: sold(session["line_items"])}

  def with_checkout(%Payment{} = payment, nil), do: payment

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

  @doc """
  Params of `POST /v1/billing/meters`: its name (the event name when it has none), the event name
  and how usage adds up. A report names its customer and value under Stripe's default payload
  keys, `stripe_customer_id` and `value`.
  """
  @spec meter_params(MishkaPay.Meter.t()) :: map()
  def meter_params(meter) do
    %{
      "display_name" => meter.name || meter.event_name,
      "event_name" => meter.event_name,
      "default_aggregation" => %{"formula" => Atom.to_string(meter.aggregation)}
    }
  end

  @doc "A Stripe billing meter as a `MishkaPay.Meter`."
  @spec meter(map()) :: {:ok, MishkaPay.Meter.t()} | {:error, Splode.Error.t()}
  def meter(meter) do
    %{
      provider: "stripe",
      id: meter["id"],
      name: meter["display_name"],
      event_name: meter["event_name"],
      aggregation: known(get_in(meter, ["default_aggregation", "formula"]), ~w(sum count last)),
      status: known(meter["status"], ~w(active inactive)),
      created_at: time(meter["created"])
    }
    |> reject_nil()
    |> MishkaPay.Meter.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc """
  Params of `POST /v1/billing/meter_events`: the customer and the value in its payload, when it
  happened, and `identifier`, Stripe's id of the report, which never counts twice.
  """
  @spec usage_params(MishkaPay.Usage.t(), String.t() | nil) :: map()
  def usage_params(usage, identifier) do
    reject_nil(%{
      "event_name" => usage.event_name,
      "payload" => %{
        "stripe_customer_id" => usage.customer_id,
        "value" => usage_value(usage.value)
      },
      "identifier" => identifier,
      "timestamp" => usage.at && DateTime.to_unix(usage.at)
    })
  end

  defp usage_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp usage_value(value), do: Integer.to_string(value)

  @doc "The usage with Stripe's answer: its `identifier` as the report's id."
  @spec usage(map(), MishkaPay.Usage.t()) :: MishkaPay.Usage.t()
  def usage(answer, usage), do: %{usage | id: answer["identifier"]}

  @doc "Params of `POST /v1/billing/meter_event_adjustments`: cancel the report by its identifier."
  @spec usage_cancellation_params(MishkaPay.UsageCancellation.t()) :: map()
  def usage_cancellation_params(cancel) do
    %{
      "event_name" => cancel.event_name,
      "type" => "cancel",
      "cancel" => %{"identifier" => cancel.usage_id}
    }
  end

  @doc "The cancel with Stripe's answer: the adjustment's `status`."
  @spec usage_cancellation(map(), MishkaPay.UsageCancellation.t()) ::
          {:ok, MishkaPay.UsageCancellation.t()}
  def usage_cancellation(answer, cancel),
    do: {:ok, %{cancel | status: known(answer["status"], ~w(pending complete))}}

  @doc """
  Params of `GET /v1/billing/meters/:id/event_summaries` for one customer: Stripe counts from and
  to whole minutes, so the window widens to them, `to` rounded up.
  """
  @spec usage_summary_params(String.t(), DateTime.t(), DateTime.t()) :: [{String.t(), String.t()}]
  def usage_summary_params(customer_id, from, to) do
    [
      {"customer", customer_id},
      {"start_time", from |> minute(0) |> Integer.to_string()},
      {"end_time", to |> minute(59) |> Integer.to_string()}
    ]
  end

  # Unix seconds at the minute `time` falls in, or the next one when `up` is 59.
  defp minute(time, up), do: div(DateTime.to_unix(time) + up, 60) * 60

  @doc """
  Stripe's summaries of a window as one `MishkaPay.UsageSummary`. Asked for without grouping,
  Stripe answers one summary for the whole window, or none when nothing was reported.
  """
  @spec usage_summary(map(), String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, MishkaPay.UsageSummary.t()} | {:error, Splode.Error.t()}
  def usage_summary(%{"data" => data}, meter_id, customer_id, params) do
    summary = List.first(data) || %{}
    window = Map.new(params)

    %{
      provider: "stripe",
      meter_id: meter_id,
      customer_id: customer_id,
      value: summary["aggregated_value"] || 0,
      from: time(summary["start_time"] || String.to_integer(window["start_time"])),
      to: time(summary["end_time"] || String.to_integer(window["end_time"]))
    }
    |> MishkaPay.UsageSummary.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc "Params of `POST /v1/entitlements/features`."
  @spec feature_params(MishkaPay.Feature.t()) :: map()
  def feature_params(feature) do
    %{
      "name" => feature.name,
      "lookup_key" => feature.lookup_key,
      "metadata" => feature.metadata
    }
  end

  @doc "A Stripe feature as a `MishkaPay.Feature`; a product feature answers the feature it attached."
  @spec feature(map()) :: {:ok, MishkaPay.Feature.t()} | {:error, Splode.Error.t()}
  def feature(%{"object" => "product_feature", "entitlement_feature" => feature}),
    do: feature(feature)

  def feature(feature) do
    %{
      provider: "stripe",
      id: feature["id"],
      name: feature["name"],
      lookup_key: feature["lookup_key"],
      active: feature["active"],
      metadata: feature["metadata"]
    }
    |> reject_nil()
    |> MishkaPay.Feature.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc "A Stripe active entitlement as a `MishkaPay.Entitlement`."
  @spec entitlement(map()) :: {:ok, MishkaPay.Entitlement.t()} | {:error, Splode.Error.t()}
  def entitlement(entitlement) do
    %{
      provider: "stripe",
      id: entitlement["id"],
      feature_id: id_of(entitlement["feature"]),
      lookup_key: entitlement["lookup_key"]
    }
    |> MishkaPay.Entitlement.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc """
  The Stripe balance as a `MishkaPay.Balance`: its payments balance, available and pending, one
  money per currency, each below zero when Stripe's is.
  """
  @spec balance(map()) :: {:ok, MishkaPay.Balance.t()} | {:error, Splode.Error.t()}
  def balance(balance) do
    %{
      provider: "stripe",
      available: funds(balance["available"]),
      pending: funds(balance["pending"])
    }
    |> MishkaPay.Balance.builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp funds(funds) when is_list(funds) do
    for fund <- funds,
        money = signed_money(fund["amount"], fund["currency"]),
        not is_nil(money),
        do: money
  end

  defp funds(_none), do: []

  @doc "A Stripe balance transaction as a `MishkaPay.BalanceTransaction`."
  @spec balance_transaction(map()) ::
          {:ok, MishkaPay.BalanceTransaction.t()} | {:error, Splode.Error.t()}
  def balance_transaction(txn) do
    currency = txn["currency"]

    %{
      provider: "stripe",
      id: txn["id"],
      amount: signed_money(txn["amount"], currency),
      fee: signed_money(txn["fee"], currency),
      net: signed_money(txn["net"], currency),
      type: txn["type"],
      source_id: id_of(txn["source"]),
      status: known(txn["status"], ~w(available pending)),
      description: txn["description"],
      available_at: time(txn["available_on"]),
      created_at: time(txn["created"])
    }
    |> MishkaPay.BalanceTransaction.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc """
  Params of `POST /v1/customers/:id/balance_transactions`: the signed amount in Stripe's places
  (below zero is credit), why, and the reference in its metadata.
  """
  @spec customer_balance_params(MishkaPay.CustomerBalanceTransaction.t()) :: map()
  def customer_balance_params(txn) do
    reject_nil(%{
      "amount" => minor(txn.amount),
      "currency" => lower_currency(txn.amount),
      "description" => txn.description,
      "metadata" => txn.reference && %{@reference => txn.reference}
    })
  end

  @doc "A Stripe customer balance transaction as a `MishkaPay.CustomerBalanceTransaction`."
  @spec customer_balance_transaction(map()) ::
          {:ok, MishkaPay.CustomerBalanceTransaction.t()} | {:error, Splode.Error.t()}
  def customer_balance_transaction(txn) do
    currency = txn["currency"]

    %{
      provider: "stripe",
      id: txn["id"],
      customer_id: id_of(txn["customer"]),
      amount: signed_money(txn["amount"], currency),
      ending_balance: signed_money(txn["ending_balance"], currency),
      type: txn["type"],
      description: txn["description"],
      invoice_id: id_of(txn["invoice"]),
      reference: get_in(txn, ["metadata", @reference]),
      created_at: time(txn["created"])
    }
    |> MishkaPay.CustomerBalanceTransaction.builder()
    |> MishkaPay.Errors.from_builder()
  end

  # What each kind of connected account is at Stripe, as its `controller`: the dashboard the
  # seller gets, who pays Stripe's fees, who answers for losses and who collects the seller's
  # details. Stripe's own `type` is deprecated in favour of these.
  @controllers %{
    express: %{
      "stripe_dashboard" => %{"type" => "express"},
      "fees" => %{"payer" => "application"},
      "losses" => %{"payments" => "application"}
    },
    standard: %{"stripe_dashboard" => %{"type" => "full"}},
    custom: %{
      "stripe_dashboard" => %{"type" => "none"},
      "fees" => %{"payer" => "application"},
      "losses" => %{"payments" => "application"},
      "requirement_collection" => "application"
    }
  }

  @doc """
  Params of `POST /v1/accounts`: the account's `controller` for its `:type`, its country, email,
  business name, the capabilities it asks for, and the reference in its metadata.
  """
  @spec connected_account_params(MishkaPay.ConnectedAccount.t()) :: map()
  def connected_account_params(account) do
    account
    |> connected_account_update_params()
    |> Map.merge(
      reject_nil(%{"controller" => @controllers[account.type], "country" => account.country})
    )
  end

  @doc "Params of `POST /v1/accounts/:id`: only the details given."
  @spec connected_account_update_params(MishkaPay.ConnectedAccount.t()) :: map()
  def connected_account_update_params(account) do
    reject_nil(%{
      "email" => account.email,
      "business_profile" => account.business_name && %{"name" => account.business_name},
      "capabilities" =>
        account.capabilities && Map.new(account.capabilities, &{&1, %{"requested" => true}}),
      "metadata" => with_reference(account.metadata, account.reference)
    })
  end

  @dashboards %{"express" => :express, "full" => :standard, "none" => :custom}
  @capability_states %{"active" => :active, "inactive" => :inactive, "pending" => :pending}

  @doc """
  A Stripe Account as a `MishkaPay.ConnectedAccount`: its kind (Stripe's `type`, else its
  dashboard), whether it takes payments and payouts, and what Stripe still needs.
  """
  @spec connected_account(map()) ::
          {:ok, MishkaPay.ConnectedAccount.t()} | {:error, Splode.Error.t()}
  def connected_account(account) do
    metadata = account["metadata"] || %{}
    states = account["capabilities"] || %{}

    %{
      provider: "stripe",
      id: account["id"],
      type:
        Map.get(@dashboards, get_in(account, ["controller", "stripe_dashboard", "type"])) ||
          known(account["type"], ~w(express standard custom)),
      country: account["country"],
      email: account["email"],
      business_name: get_in(account, ["business_profile", "name"]),
      capabilities: Map.keys(states),
      capability_status:
        Map.new(states, fn {name, state} -> {name, @capability_states[state]} end),
      charges_enabled: account["charges_enabled"] == true,
      payouts_enabled: account["payouts_enabled"] == true,
      details_submitted: account["details_submitted"] == true,
      requirements_due: get_in(account, ["requirements", "currently_due"]) || [],
      disabled_reason: get_in(account, ["requirements", "disabled_reason"]),
      default_currency: account["default_currency"],
      reference: metadata[@reference],
      metadata: Map.delete(metadata, @reference),
      created_at: time(account["created"])
    }
    |> Map.reject(fn {key, value} -> key == :type and is_nil(value) end)
    |> MishkaPay.ConnectedAccount.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @link_types %{onboarding: "account_onboarding", update: "account_update"}

  @doc "Params of `POST /v1/account_links`: the account, its kind of link and the two pages."
  @spec account_link_params(MishkaPay.AccountLink.t()) :: map()
  def account_link_params(link) do
    %{
      "account" => link.account_id,
      "type" => @link_types[link.type],
      "refresh_url" => link.refresh_url,
      "return_url" => link.return_url
    }
  end

  @doc "A Stripe account link or login link as the `MishkaPay.AccountLink` asked for, with its URL."
  @spec account_link(map(), MishkaPay.AccountLink.t()) ::
          {:ok, MishkaPay.AccountLink.t()} | {:error, Splode.Error.t()}
  def account_link(answer, link) do
    {:ok,
     %{
       link
       | url: answer["url"],
         expires_at: time(answer["expires_at"]),
         created_at: time(answer["created"])
     }}
  end

  @doc """
  Params of `POST /v1/transfers`: the amount in Stripe's places, the connected account, the sale
  it pays out of, its group and the reference in its metadata.
  """
  @spec transfer_params(MishkaPay.Transfer.t()) :: map()
  def transfer_params(transfer) do
    reject_nil(%{
      "amount" => minor(transfer.amount),
      "currency" => lower_currency(transfer.amount),
      "destination" => transfer.destination,
      "source_transaction" => transfer.source_charge_id,
      "transfer_group" => transfer.transfer_group,
      "description" => transfer.description,
      "metadata" => with_reference(transfer.metadata, transfer.reference)
    })
  end

  @doc "A Stripe Transfer as a `MishkaPay.Transfer`, with what was taken back of it."
  @spec transfer(map()) :: {:ok, MishkaPay.Transfer.t()} | {:error, Splode.Error.t()}
  def transfer(transfer) do
    currency = transfer["currency"]
    metadata = transfer["metadata"] || %{}

    %{
      provider: "stripe",
      id: transfer["id"],
      amount: money(transfer["amount"], currency),
      amount_reversed: money(transfer["amount_reversed"], currency),
      reversed: transfer["reversed"] == true,
      destination: id_of(transfer["destination"]),
      destination_payment_id: id_of(transfer["destination_payment"]),
      source_charge_id: id_of(transfer["source_transaction"]),
      transfer_group: transfer["transfer_group"],
      description: transfer["description"],
      reference: metadata[@reference],
      metadata: Map.delete(metadata, @reference),
      created_at: time(transfer["created"])
    }
    |> MishkaPay.Transfer.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc """
  Params of a part given back (a transfer reversal, an application fee refund): the amount in
  Stripe's places, or none for all of it, and the object it belongs to expanded in the answer.
  """
  @spec part_params(Elixir.Money.t() | nil, String.t()) :: [{String.t(), String.t()}]
  def part_params(nil, expand), do: [{"expand[]", expand}]

  def part_params(amount, expand),
    do: [{"amount", Integer.to_string(minor(amount))} | part_params(nil, expand)]

  @doc "A Stripe Payout as a `MishkaPay.Payout`."
  @spec payout(map()) :: {:ok, MishkaPay.Payout.t()} | {:error, Splode.Error.t()}
  def payout(payout) do
    %{
      provider: "stripe",
      id: payout["id"],
      amount: money(payout["amount"], payout["currency"]),
      status: known(payout["status"], ~w(pending in_transit paid failed canceled)),
      arrival_at: time(payout["arrival_date"]),
      automatic: payout["automatic"] == true,
      method: payout["method"],
      destination_id: id_of(payout["destination"]),
      failure_code: payout["failure_code"],
      failure_message: payout["failure_message"],
      description: payout["description"],
      created_at: time(payout["created"])
    }
    |> MishkaPay.Payout.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc "A Stripe application fee as a `MishkaPay.ApplicationFee`."
  @spec application_fee(map()) ::
          {:ok, MishkaPay.ApplicationFee.t()} | {:error, Splode.Error.t()}
  def application_fee(fee) do
    currency = fee["currency"]

    %{
      provider: "stripe",
      id: fee["id"],
      amount: money(fee["amount"], currency),
      amount_refunded: money(fee["amount_refunded"], currency),
      refunded: fee["refunded"] == true,
      account_id: id_of(fee["account"]),
      charge_id: id_of(fee["charge"]),
      created_at: time(fee["created"])
    }
    |> MishkaPay.ApplicationFee.builder()
    |> MishkaPay.Errors.from_builder()
  end

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

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
    Customer,
    Event,
    Invoice,
    Money,
    Payment,
    PaymentLink,
    PortalSession,
    Price,
    Product,
    Refund,
    ShippingRate,
    Subscription,
    TaxCalculation
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
    |> Map.merge(mode_data(checkout, reference, settings))
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
  # The page the buyer comes back to names the session as `session_id`, unless the caller put
  # Stripe's `{CHECKOUT_SESSION_ID}` in it already: `MishkaPay.return_checkout_id/2` reads it.
  defp ui_params(%Checkout{ui_mode: :embedded} = checkout),
    do: %{"ui_mode" => "embedded_page", "return_url" => with_session(checkout.return_url)}

  defp ui_params(checkout),
    do: %{
      "success_url" => with_session(checkout.success_url),
      "cancel_url" => checkout.cancel_url
    }

  @session "{CHECKOUT_SESSION_ID}"

  @doc false
  @spec with_session(String.t() | nil) :: String.t() | nil
  def with_session(nil), do: nil

  def with_session(url) do
    case String.contains?(url, @session) do
      true ->
        url

      false ->
        url <> if(String.contains?(url, "?"), do: "&", else: "?") <> "session_id=" <> @session
    end
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
  defp shipping_option(id) when is_binary(id), do: %{"shipping_rate" => id}
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

  defp mode_data(
         %Checkout{mode: :subscription, trial_days: days} = checkout,
         reference,
         settings
       ),
       do: %{
         "subscription_data" =>
           %{
             "metadata" => reference,
             "billing_mode" => billing_mode(checkout, settings),
             "trial_period_days" => days,
             "description" => checkout.description,
             "application_fee_percent" =>
               checkout.application_fee_percent &&
                 Decimal.to_string(checkout.application_fee_percent, :normal)
           }
           |> Map.merge(seller(checkout))
           |> reject_nil()
       }

  defp mode_data(%Checkout{mode: :setup} = checkout, reference, _settings),
    do: %{
      "setup_intent_data" =>
        reject_nil(%{"metadata" => reference, "description" => checkout.description})
    }

  defp mode_data(checkout, reference, _settings),
    do: %{
      "payment_intent_data" =>
        %{
          "metadata" => reference,
          "description" => checkout.description,
          "statement_descriptor_suffix" => checkout.statement_suffix,
          "capture_method" => capture_method(checkout.capture),
          "application_fee_amount" => minor_of(checkout.application_fee)
        }
        |> Map.merge(seller(checkout))
        |> reject_nil()
    }

  @doc """
  Stripe's `billing_mode` of a subscription made from `choice` (a checkout or a new schedule):
  its own `:billing_mode`, else the tenant's (`settings`), else `flexible`, Stripe's recommended
  mode; in the flexible mode, its `:proration_discounts`, else the tenant's, else `itemized`, the
  way Stripe recommends.
  """
  @spec billing_mode(map(), map()) :: map()
  def billing_mode(choice, settings) do
    discounts =
      Map.get(choice, :proration_discounts) || Map.get(settings, :proration_discounts) ||
        :itemized

    choice |> billing_type(settings) |> billing_mode_of(discounts)
  end

  @doc """
  The billing mode a subscription made from `choice` gets: its own `:billing_mode`, else the
  tenant's (`settings`), else `:flexible`.
  """
  @spec billing_type(map(), map()) :: :flexible | :classic
  def billing_type(choice, settings),
    do: Map.get(choice, :billing_mode) || Map.get(settings, :billing_mode) || :flexible

  defp billing_mode_of(:classic, _discounts), do: %{"type" => "classic"}

  defp billing_mode_of(:flexible, discounts),
    do: %{"type" => "flexible", "flexible" => %{"proration_discounts" => to_string(discounts)}}

  # Stripe takes the money at once with `automatic_async`, its default and recommended way (it
  # answers sooner than `automatic`, still there for a site that asks for it); `manual` holds
  # it. Left out, Stripe's default applies.
  defp capture_method(nil), do: nil
  defp capture_method(:automatic), do: "automatic_async"
  defp capture_method(:automatic_sync), do: "automatic"
  defp capture_method(:manual), do: "manual"

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
               "options" => Enum.map(field.options, &%{"value" => &1.value, "label" => &1.label})
             }) ||
            nil
      })
    end
  end

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

  defp line_item(%Price{id: id, quantity: quantity} = price) when is_binary(id),
    do: reject_nil(%{"price" => id, "quantity" => quantity, "tax_rates" => price.tax_rate_ids})

  defp line_item(%Price{amount: amount, quantity: quantity} = price) do
    %{
      "tax_rates" => price.tax_rate_ids,
      "price_data" =>
        %{
          "currency" => amount.currency |> to_string() |> String.downcase(),
          "unit_amount" => minor(amount),
          "tax_behavior" => price.tax_behavior && Atom.to_string(price.tax_behavior)
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.merge(line_product(price))
        |> Map.merge(recurring(price)),
      "quantity" => quantity
    }
    |> reject_nil()
  end

  # An inline price of a product Stripe already has names it, so the product's own name and tax
  # code apply (Managed Payments refuses a line with no tax code); otherwise the product is made
  # inline from the line's name and tax code.
  defp line_product(%Price{product_id: product}) when is_binary(product),
    do: %{"product" => product}

  defp line_product(%Price{name: name, tax_code: tax_code}),
    do: %{"product_data" => reject_nil(%{"name" => name, "tax_code" => tax_code})}

  defp recurring(%Price{interval: nil}), do: %{}

  defp recurring(%Price{interval: interval, interval_count: count}),
    do: %{"recurring" => %{"interval" => Atom.to_string(interval), "interval_count" => count}}

  defp buyer_params(%{id: id}) when is_binary(id), do: with_customer(%{}, id)
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
  @spec portal_configuration_params(PortalSession.Configuration.t()) :: map()
  def portal_configuration_params(%PortalSession.Configuration{} = config) do
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

  @doc "A Stripe portal configuration (`billing_portal.configuration`) as a `MishkaPay.PortalSession.Configuration`."
  @spec portal_configuration(map()) ::
          {:ok, PortalSession.Configuration.t()} | {:error, Splode.Error.t()}
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
    |> PortalSession.Configuration.builder()
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
    case {customer_ref(session), get_in(session, ["customer_details", "email"])} do
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
      customer_id: customer_ref(intent),
      customer_email: customer["email"] || billing["email"] || intent["receipt_email"],
      customer_name: customer["name"] || billing["name"]
    }
  end

  # How it was paid, its receipt, and why the last try failed.
  defp charge_of(intent, charge) do
    card = get_in(charge, ["payment_method_details", "card"]) || %{}
    failure = intent["last_payment_error"] || %{}

    balance = expanded(charge["balance_transaction"])

    %{
      charge_id: id_of(intent["latest_charge"]),
      balance_transaction_id: id_of(charge["balance_transaction"]),
      fee: money(balance["fee"], balance["currency"]),
      payment_method: get_in(charge, ["payment_method_details", "type"]),
      card_brand: card["brand"],
      card_last4: card["last4"],
      receipt_url: charge["receipt_url"],
      failure_code: failure["decline_code"] || failure["code"],
      failure_message: failure["message"]
    }
  end

  @subscription_statuses ~w(incomplete incomplete_expired trialing active past_due unpaid paused canceled)a
  @invoice_statuses ~w(draft open paid uncollectible void)a

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
      customer_id: customer_ref(sub),
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

  defp interval(interval) when is_binary(interval), do: known(interval, ~w(day week month year)a)
  defp interval(_none), do: nil

  @customer_includes ~w(configuration.customer identity)

  @doc """
  Params of making or changing a customer. `:v1`: `POST /v1/customers` (and its update), the
  fields set, the address, the invoice default and the reference in the metadata. `:v2`: `POST
  /v2/core/accounts` (and its update), an account with the customer configuration: the email as
  `contact_email`, the name as `display_name`, the phone and address under the identity's
  individual, the invoice default under the configuration's billing, and the reference in the
  metadata. A field left out is not sent, so an update changes only what it names.
  """
  @spec customer_params(Customer.t(), :v2 | :v1) :: map()
  def customer_params(%Customer{} = customer, :v1) do
    reject_nil(%{
      "email" => customer.email,
      "name" => customer.name,
      "phone" => customer.phone,
      "address" => customer.address && address_params(customer.address),
      "invoice_settings" => keyed("default_payment_method", customer.default_payment_method),
      "metadata" => with_reference(customer.metadata, customer.reference)
    })
  end

  def customer_params(%Customer{} = customer, :v2) do
    billing = keyed("default_payment_method", customer.default_payment_method)

    reject_nil(%{
      "contact_email" => customer.email,
      "display_name" => customer.name,
      "identity" => customer_identity(customer),
      "configuration" => %{"customer" => reject_nil(%{"billing" => billing})},
      "metadata" => with_reference(customer.metadata, customer.reference),
      "include" => @customer_includes
    })
  end

  defp customer_identity(%Customer{phone: nil, address: nil}), do: nil

  defp customer_identity(%Customer{phone: phone, address: address}) do
    individual = reject_nil(%{"phone" => phone, "address" => address && address_params(address)})
    reject_nil(%{"country" => address && address.country, "individual" => individual})
  end

  @doc "What a v2 customer read includes: its customer configuration and identity."
  @spec customer_includes() :: [String.t()]
  def customer_includes, do: @customer_includes

  @doc """
  A Stripe customer as a `MishkaPay.Customer`: a `v2.core.account` with the customer
  configuration, or a v1 `customer`. A deleted Customer or a closed account is a rejection with
  code `"customer_deleted"`, and an account without the customer configuration one with
  `"resource_missing"`. `view` is the API the tenant names its customers by: on `:v2` a Customer
  that Stripe links to an account (one made on Accounts v2, read through `/v1/customers`)
  answers the account's id.
  """
  @spec customer(map(), :v2 | :v1) :: {:ok, Customer.t()} | {:error, Splode.Error.t()}
  def customer(customer, view \\ :v1)

  def customer(%{"deleted" => true, "id" => id}, _view),
    do: no_customer("customer_deleted", "Customer #{id} was deleted")

  def customer(%{"object" => "v2.core.account"} = account, _view),
    do: account_customer(account, "customer" in List.wrap(account["applied_configurations"]))

  def customer(customer, view) do
    id = linked_id(customer, view)

    customer
    |> account_common()
    |> Map.merge(%{
      id: id,
      api: api_of_customer(id),
      email: customer["email"],
      name: customer["name"],
      phone: customer["phone"],
      address: customer_address(customer["address"]),
      default_payment_method:
        id_of(get_in(customer, ["invoice_settings", "default_payment_method"])),
      created_at: time(customer["created"])
    })
    |> built_customer()
  end

  # A closed account keeps its configurations listed: a seller's closed account is no customer.
  defp account_customer(%{"closed" => true, "id" => id}, true),
    do: no_customer("customer_deleted", "Customer #{id} was closed")

  defp account_customer(account, true) do
    individual = get_in(account, ["identity", "individual"]) || %{}

    account
    |> account_common()
    |> Map.merge(%{
      api: :v2,
      email: account["contact_email"],
      name: account["display_name"],
      phone: individual["phone"],
      address: customer_address(individual["address"]),
      default_payment_method:
        get_in(account, ["configuration", "customer", "billing", "default_payment_method"]),
      created_at: time(account["created"])
    })
    |> built_customer()
  end

  defp account_customer(%{"id" => id}, false),
    do: no_customer("resource_missing", "Account #{id} is not a customer")

  defp linked_id(%{"customer_account" => "acct_" <> _ = account_id}, :v2), do: account_id
  defp linked_id(customer, _view), do: customer["id"]

  @doc false
  def api_of_customer("acct_" <> _id), do: :v2
  def api_of_customer(_id), do: :v1

  defp customer_address(address) do
    case address(address) do
      nil -> nil
      fields -> struct(Address, fields)
    end
  end

  defp built_customer(attrs) do
    attrs
    |> Map.reject(fn {_field, value} -> value in ["", nil] end)
    |> Customer.builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp no_customer(code, message) do
    {:error,
     MishkaPay.Errors.Rejected.exception(
       provider: "stripe",
       status: 404,
       code: code,
       message: message
     )}
  end

  @tax_id_checks %{
    "pending" => :pending,
    "verified" => :verified,
    "unverified" => :unverified,
    "unavailable" => :unavailable
  }

  @doc "Params of `POST /v1/customers/:id/tax_ids`: its kind and its number."
  @spec tax_id_params(Customer.TaxId.t()) :: map()
  def tax_id_params(%Customer.TaxId{} = tax_id),
    do: %{"type" => tax_id.type, "value" => tax_id.value}

  @doc "A Stripe tax id (`object: \"tax_id\"`) as a `MishkaPay.Customer.TaxId`, with its register check."
  @spec tax_id(map()) :: {:ok, Customer.TaxId.t()} | {:error, Splode.Error.t()}
  def tax_id(tax_id) do
    check = tax_id["verification"] || %{}

    %{
      provider: "stripe",
      id: tax_id["id"],
      customer_id: customer_ref(tax_id),
      type: tax_id["type"],
      value: tax_id["value"],
      country: tax_id["country"],
      verification: Map.get(@tax_id_checks, check["status"]),
      verified_name: blank(check["verified_name"]),
      verified_address: blank(check["verified_address"]),
      created_at: time(tax_id["created"])
    }
    |> Customer.TaxId.builder()
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

  defp tax_line_params(%TaxCalculation.Items{} = line) do
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
      customer_id: customer_ref(calculation),
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

  @address_fields %{
    "country" => :country,
    "postal_code" => :postal_code,
    "line1" => :line1,
    "line2" => :line2,
    "city" => :city,
    "state" => :state
  }

  # A Stripe address, its empty fields left out; none without a country.
  defp address(%{"country" => country} = address) when is_binary(country) do
    address
    |> Map.take(Map.keys(@address_fields))
    |> Map.new(fn {field, value} -> {Map.fetch!(@address_fields, field), blank(value)} end)
    |> reject_nil()
  end

  defp address(_none), do: nil

  @doc """
  Params of `POST /v1/payment_intents` and `POST /v1/payment_intents/:id`: the fields set, the
  amount in Stripe's units with its currency, and the reference and owner in the metadata.
  """
  @spec payment_intent_params(MishkaPay.PaymentIntent.t()) :: map()
  def payment_intent_params(%MishkaPay.PaymentIntent{} = intent) do
    reject_nil(%{
      "amount" => intent.amount && minor(intent.amount),
      "currency" => intent.amount && lower_currency(intent.amount),
      "payment_method" => intent.payment_method_id,
      "capture_method" => capture_method(intent.capture),
      "setup_future_usage" =>
        intent.setup_future_usage && Atom.to_string(intent.setup_future_usage),
      "automatic_payment_methods" => automatic_methods(intent),
      "description" => intent.description,
      "metadata" =>
        intent.metadata
        |> with_reference(intent.reference)
        |> with_owner(intent.owner)
    })
    |> with_customer(intent.customer_id)
  end

  @doc "Params of `POST /v1/setup_intents`: the fields set, and the reference in the metadata."
  @spec setup_intent_params(MishkaPay.SetupIntent.t()) :: map()
  def setup_intent_params(%MishkaPay.SetupIntent{} = intent) do
    reject_nil(%{
      "payment_method" => intent.payment_method_id,
      "usage" => intent.usage && Atom.to_string(intent.usage),
      "automatic_payment_methods" => automatic_methods(intent),
      "description" => intent.description,
      "metadata" => with_reference(intent.metadata, intent.reference)
    })
    |> with_customer(intent.customer_id)
  end

  # A new intent offers the dashboard's payment methods unless told cards only; a change leaves
  # them as they are.
  defp automatic_methods(%{id: nil, automatic_payment_methods: false}),
    do: %{"enabled" => false}

  defp automatic_methods(%{id: nil}), do: %{"enabled" => true}
  defp automatic_methods(_change), do: nil

  defp with_owner(metadata, nil), do: metadata
  defp with_owner(metadata, owner), do: Map.put(metadata || %{}, @owner, owner)

  @doc "Params of an intent's `confirm`: the payment method and the page to come back to."
  @spec confirm_params(keyword()) :: map()
  def confirm_params(opts),
    do:
      reject_nil(%{
        "payment_method" => opts[:payment_method_id],
        "return_url" => opts[:return_url]
      })

  @future_usages %{"on_session" => :on_session, "off_session" => :off_session}
  @payment_intent_statuses Map.new(MishkaPay.PaymentIntent.statuses(), &{Atom.to_string(&1), &1})
  @setup_intent_statuses Map.new(MishkaPay.SetupIntent.statuses(), &{Atom.to_string(&1), &1})

  @doc "A Stripe PaymentIntent as a `MishkaPay.PaymentIntent`, for a page with Stripe Elements."
  @spec payment_intent(map()) :: {:ok, MishkaPay.PaymentIntent.t()} | {:error, Splode.Error.t()}
  def payment_intent(intent) do
    currency = intent["currency"]

    %{
      provider: "stripe",
      id: intent["id"],
      amount: money(intent["amount"], currency),
      amount_received: money(intent["amount_received"], currency),
      customer_id: customer_ref(intent),
      payment_method_id: id_of(intent["payment_method"]),
      capture: capture_of(intent["capture_method"]),
      setup_future_usage: Map.get(@future_usages, intent["setup_future_usage"]),
      automatic_payment_methods: get_in(intent, ["automatic_payment_methods", "enabled"]),
      description: intent["description"],
      reference: get_in(intent, ["metadata", @reference]),
      owner: get_in(intent, ["metadata", @owner]),
      metadata: Map.drop(intent["metadata"] || %{}, [@reference, @owner]),
      client_secret: intent["client_secret"],
      status: Map.get(@payment_intent_statuses, intent["status"])
    }
    |> Map.merge(intent_failure(intent["last_payment_error"], intent["created"]))
    |> reject_nil()
    |> MishkaPay.PaymentIntent.builder()
    |> MishkaPay.Errors.from_builder()
  end

  # `automatic` and `automatic_async` both take the money at once; only `manual` holds it.
  defp capture_of("manual"), do: :manual
  defp capture_of(_automatic), do: :automatic

  @doc "A Stripe SetupIntent as a `MishkaPay.SetupIntent`, for a page with Stripe Elements."
  @spec setup_intent(map()) :: {:ok, MishkaPay.SetupIntent.t()} | {:error, Splode.Error.t()}
  def setup_intent(intent) do
    %{
      provider: "stripe",
      id: intent["id"],
      customer_id: customer_ref(intent),
      payment_method_id: id_of(intent["payment_method"]),
      usage: Map.get(@future_usages, intent["usage"]),
      automatic_payment_methods: get_in(intent, ["automatic_payment_methods", "enabled"]),
      description: intent["description"],
      reference: get_in(intent, ["metadata", @reference]),
      metadata: Map.delete(intent["metadata"] || %{}, @reference),
      client_secret: intent["client_secret"],
      status: Map.get(@setup_intent_statuses, intent["status"])
    }
    |> Map.merge(intent_failure(intent["last_setup_error"], intent["created"]))
    |> reject_nil()
    |> MishkaPay.SetupIntent.builder()
    |> MishkaPay.Errors.from_builder()
  end

  # Why the last try failed: the decline code when the card's bank gave one.
  defp intent_failure(error, created) do
    error = error || %{}

    %{
      failure_code: error["decline_code"] || error["code"],
      failure_message: error["message"],
      created_at: time(created)
    }
  end

  @doc """
  Params of `POST /v1/tax_rates` and `POST /v1/tax_rates/:id`: the fields set, with the reference
  in the metadata. A change never sets the percentage or whether it is inclusive.
  """
  @spec tax_rate_params(MishkaPay.TaxRate.t()) :: map()
  def tax_rate_params(%MishkaPay.TaxRate{} = rate) do
    reject_nil(%{
      "display_name" => rate.display_name,
      "percentage" =>
        on_create(rate, rate.percentage && Decimal.to_string(rate.percentage, :normal)),
      "inclusive" => on_create(rate, rate.inclusive),
      "active" => rate.active,
      "country" => rate.country,
      "state" => rate.state,
      "jurisdiction" => rate.jurisdiction,
      "tax_type" => rate.tax_type,
      "description" => rate.description,
      "metadata" => with_reference(rate.metadata, rate.reference)
    })
  end

  defp on_create(%MishkaPay.TaxRate{id: nil}, value), do: value
  defp on_create(_change, _value), do: nil

  @doc "A Stripe Tax Rate as a `MishkaPay.TaxRate`."
  @spec tax_rate(map()) :: {:ok, MishkaPay.TaxRate.t()} | {:error, Splode.Error.t()}
  def tax_rate(rate) do
    %{
      provider: "stripe",
      id: rate["id"],
      display_name: rate["display_name"],
      percentage: percent(rate["percentage"]),
      effective_percentage: percent(rate["effective_percentage"]),
      inclusive: rate["inclusive"],
      active: rate["active"],
      country: blank(rate["country"]),
      state: blank(rate["state"]),
      jurisdiction: blank(rate["jurisdiction"]),
      tax_type: blank(rate["tax_type"]),
      description: blank(rate["description"]),
      reference: get_in(rate, ["metadata", @reference]),
      metadata: Map.delete(rate["metadata"] || %{}, @reference),
      created_at: time(rate["created"])
    }
    |> reject_nil()
    |> MishkaPay.TaxRate.builder()
    |> MishkaPay.Errors.from_builder()
  end

  # Stripe answers a percentage as a JSON number.
  defp percent(value) when is_integer(value), do: Decimal.new(value)
  defp percent(value) when is_float(value), do: Decimal.from_float(value)
  defp percent(_none), do: nil

  # The tax rates on a line, expanded or by id.
  defp tax_rate_ids([_ | _] = rates), do: Enum.map(rates, &id_of/1)
  defp tax_rate_ids(_none), do: nil

  @doc """
  Params of `POST /v1/tax/registrations`: the country, and its kind (and state or province, or
  a standard registration's place of supply scheme) under the country's own `country_options`;
  it starts now unless `:active_from` says when.
  """
  @spec tax_registration_params(MishkaPay.TaxSettings.Registration.t()) :: map()
  def tax_registration_params(%MishkaPay.TaxSettings.Registration{} = registration) do
    country = String.downcase(registration.country)

    %{
      "country" => registration.country,
      "country_options" => %{country => registration_options(registration)},
      "active_from" => (registration.active_from && unix(registration.active_from)) || "now",
      "expires_at" => unix(registration.expires_at)
    }
    |> reject_nil()
  end

  # Canada names a province only for a provincial registration; the US names its state for each.
  defp registration_options(%{country: "CA", type: "province_standard" = type, state: state}),
    do: %{"type" => type, type => %{"province" => state}}

  defp registration_options(%{country: "US", type: type, state: state}),
    do: %{"type" => type, "state" => state}

  defp registration_options(%{type: type, place_of_supply_scheme: scheme})
       when not is_nil(scheme),
       do: %{"type" => type, type => %{"place_of_supply_scheme" => Atom.to_string(scheme)}}

  defp registration_options(%{type: type}), do: %{"type" => type}

  @registration_statuses %{"active" => :active, "scheduled" => :scheduled, "expired" => :expired}
  @supply_schemes %{
    "inbound_goods" => :inbound_goods,
    "small_seller" => :small_seller,
    "standard" => :standard
  }

  @doc "A Stripe Tax Registration as a `MishkaPay.TaxSettings.Registration`."
  @spec tax_registration(map()) ::
          {:ok, MishkaPay.TaxSettings.Registration.t()} | {:error, Splode.Error.t()}
  def tax_registration(registration) do
    country = registration["country"]
    options = get_in(registration, ["country_options", String.downcase(country || "")]) || %{}
    type = options["type"]

    %{
      provider: "stripe",
      id: registration["id"],
      country: country,
      type: type,
      state: options["state"] || get_in(options, [type || "", "province"]),
      place_of_supply_scheme:
        Map.get(@supply_schemes, get_in(options, [type || "", "place_of_supply_scheme"])),
      status: Map.get(@registration_statuses, registration["status"]),
      active_from: time(registration["active_from"]),
      expires_at: time(registration["expires_at"]),
      created_at: time(registration["created"])
    }
    |> reject_nil()
    |> MishkaPay.TaxSettings.Registration.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc "Params of `POST /v1/tax/settings`: only the head office and defaults given."
  @spec tax_settings_params(MishkaPay.TaxSettings.t()) :: map()
  def tax_settings_params(%MishkaPay.TaxSettings{} = settings) do
    defaults =
      reject_nil(%{
        "tax_code" => settings.tax_code,
        "tax_behavior" => settings.tax_behavior && Atom.to_string(settings.tax_behavior)
      })

    reject_nil(%{
      "head_office" =>
        settings.head_office && %{"address" => address_params(settings.head_office)},
      "defaults" => (defaults != %{} && defaults) || nil
    })
  end

  @settings_behaviors %{
    "inclusive" => :inclusive,
    "exclusive" => :exclusive,
    "inferred_by_currency" => :inferred_by_currency
  }

  @doc "Stripe Tax's settings (`tax.settings`) as a `MishkaPay.TaxSettings`."
  @spec tax_settings(map()) :: {:ok, MishkaPay.TaxSettings.t()} | {:error, Splode.Error.t()}
  def tax_settings(settings) do
    office = address(get_in(settings, ["head_office", "address"]))

    %{
      provider: "stripe",
      head_office: office && struct(Address, office),
      tax_code: get_in(settings, ["defaults", "tax_code"]),
      tax_behavior: Map.get(@settings_behaviors, get_in(settings, ["defaults", "tax_behavior"])),
      status: Map.get(%{"active" => :active, "pending" => :pending}, settings["status"]),
      missing_fields: get_in(settings, ["status_details", "pending", "missing_fields"])
    }
    |> reject_nil()
    |> MishkaPay.TaxSettings.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc "A Stripe Tax Transaction as a `MishkaPay.TaxCalculation.Transaction`, made from `calculation_id`."
  @spec tax_transaction(map(), String.t()) ::
          {:ok, TaxCalculation.Transaction.t()} | {:error, Splode.Error.t()}
  def tax_transaction(transaction, calculation_id) do
    %{
      provider: "stripe",
      id: transaction["id"],
      reference: transaction["reference"],
      calculation_id: calculation_id,
      customer_id: customer_ref(transaction),
      posted_at: time(transaction["posted_at"]),
      created_at: time(transaction["created"])
    }
    |> TaxCalculation.Transaction.builder()
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
      customer_id: customer_ref(invoice),
      period_start: time(invoice["period_start"]),
      period_end: time(invoice["period_end"]),
      hosted_url: invoice["hosted_invoice_url"],
      pdf_url: invoice["invoice_pdf"],
      payment_id: id_of(invoice["payment_intent"]) || paid_by(invoice),
      number: invoice["number"],
      collection: known(invoice["collection_method"], ~w(charge_automatically send_invoice)a),
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
  @spec invoice_params(MishkaPay.Invoice.Draft.t()) :: map()
  def invoice_params(draft) do
    %{
      "collection_method" => Atom.to_string(draft.collection),
      "days_until_due" =>
        (draft.collection == :send_invoice && (draft.days_until_due || 30)) || nil,
      "description" => draft.description,
      "footer" => draft.footer,
      "auto_advance" => false,
      "pending_invoice_items_behavior" => "exclude",
      "currency" => draft_currency(draft.items),
      "default_tax_rates" => draft.tax_rate_ids,
      "metadata" =>
        Map.merge(
          draft.metadata || %{},
          (draft.reference && %{@reference => draft.reference}) || %{}
        )
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> with_customer(draft.customer_id)
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
    |> Map.put("invoice", invoice_id)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> with_customer(customer_id)
  end

  @doc """
  Params of `POST /v1/invoiceitems` for a `MishkaPay.Invoice.Item` made on its own: the line a
  draft's item sends (`invoice_item_params/3`), with the reference in its metadata.
  """
  @spec invoice_item_params(Invoice.Item.t()) :: map()
  def invoice_item_params(%Invoice.Item{} = item) do
    item
    |> Invoice.item_price()
    |> invoice_item_params(item.invoice_id, item.customer_id)
    |> Map.merge(item_metadata(item))
  end

  @doc """
  Params of `POST /v1/invoiceitems/:id`: only what the change sets. Stripe keeps the item's
  currency, so the amount is sent in its places without one.
  """
  @spec invoice_item_update_params(Invoice.Item.t()) :: map()
  def invoice_item_update_params(%Invoice.Item{} = item) do
    item
    |> Invoice.item_price()
    |> charge_params()
    |> Map.delete("currency")
    |> Map.merge(item_metadata(item))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # What one line charges: a catalog price by id, or a name with the price of one.
  defp charge_params(%Price{id: id, quantity: quantity} = price) when is_binary(id),
    do: %{
      "pricing" => %{"price" => id},
      "quantity" => quantity,
      "tax_rates" => price.tax_rate_ids
    }

  defp charge_params(%Price{amount: amount} = price) do
    %{
      "description" => price.name,
      "currency" => amount && amount.currency |> to_string() |> String.downcase(),
      "unit_amount_decimal" => amount && amount |> minor() |> Integer.to_string(),
      "quantity" => price.quantity,
      "tax_code" => price.tax_code,
      "tax_behavior" => price.tax_behavior && Atom.to_string(price.tax_behavior),
      "tax_rates" => price.tax_rate_ids
    }
  end

  defp item_metadata(%Invoice.Item{} = item) do
    case with_reference(item.metadata, item.reference) do
      nil -> %{}
      metadata -> %{"metadata" => metadata}
    end
  end

  @doc "A Stripe invoice item (`object: \"invoiceitem\"`) as a `MishkaPay.Invoice.Item`."
  @spec invoice_item(map()) :: {:ok, Invoice.Item.t()} | {:error, Splode.Error.t()}
  def invoice_item(item) do
    currency = item["currency"]

    %{
      provider: "stripe",
      id: item["id"],
      customer_id: customer_ref(item),
      invoice_id: id_of(item["invoice"]),
      price_id: id_of(get_in(item, ["pricing", "price_details", "price"])),
      name: blank(item["description"]),
      amount: unit_money(get_in(item, ["pricing", "unit_amount_decimal"]), currency),
      quantity: item["quantity"],
      total: signed_money(item["amount"], currency),
      period_start: time(get_in(item, ["period", "start"])),
      period_end: time(get_in(item, ["period", "end"])),
      tax_rate_ids: tax_rate_ids(item["tax_rates"]),
      reference: get_in(item, ["metadata", @reference]),
      metadata: Map.delete(item["metadata"] || %{}, @reference),
      created_at: time(item["date"])
    }
    |> Invoice.Item.builder()
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
  else with it, metadata and billing mode neither), or the customer, its start (now unless
  given), the phases and what happens after them, its billing mode (`billing_mode/2`, with the
  tenant's `settings`), with the reference in its metadata.
  """
  @spec subscription_schedule_params(Subscription.Schedule.t(), map()) :: map()
  def subscription_schedule_params(schedule, settings \\ %{})

  def subscription_schedule_params(%Subscription.Schedule{subscription_id: id}, _settings)
      when is_binary(id),
      do: %{"from_subscription" => id}

  def subscription_schedule_params(%Subscription.Schedule{} = schedule, settings) do
    %{
      "billing_mode" => billing_mode(schedule, settings),
      "start_date" => unix(schedule.start_at) || "now",
      "end_behavior" => schedule.end_behavior && Atom.to_string(schedule.end_behavior),
      "phases" => Enum.map(schedule.phases, &phase_params/1),
      "metadata" => schedule_metadata(schedule)
    }
    |> reject_nil()
    |> with_customer(schedule.customer_id)
  end

  @doc "Params of `POST /v1/subscription_schedules/:id`: only what the change sets."
  @spec subscription_schedule_update_params(Subscription.Schedule.t()) :: map()
  def subscription_schedule_update_params(%Subscription.Schedule{} = schedule) do
    reject_nil(%{
      "end_behavior" => schedule.end_behavior && Atom.to_string(schedule.end_behavior),
      "phases" => schedule.phases && Enum.map(schedule.phases, &phase_params/1),
      "proration_behavior" => schedule.proration && Atom.to_string(schedule.proration),
      "metadata" => schedule_metadata(schedule)
    })
  end

  defp schedule_metadata(schedule), do: with_reference(schedule.metadata, schedule.reference)

  # This API version takes a phase's length as a `duration`; `iterations` is gone.
  defp phase_params(%Subscription.Schedule.Phases{} = phase) do
    reject_nil(%{
      "items" =>
        Enum.map(
          phase.items,
          &reject_nil(%{
            "price" => &1.id,
            "quantity" => &1.quantity,
            "tax_rates" => &1.tax_rate_ids
          })
        ),
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
  A Stripe subscription schedule as a `MishkaPay.Subscription.Schedule`: its phases with their
  dates, and which of them runs now.
  """
  @spec subscription_schedule(map()) ::
          {:ok, Subscription.Schedule.t()} | {:error, Splode.Error.t()}
  def subscription_schedule(schedule) do
    phases = schedule["phases"] |> List.wrap() |> Enum.map(&phase/1)
    current = get_in(schedule, ["current_phase", "start_date"])

    %{
      provider: "stripe",
      id: schedule["id"],
      customer_id: customer_ref(schedule),
      subscription_id: id_of(schedule["subscription"]),
      released_subscription_id: id_of(schedule["released_subscription"]),
      status: known(schedule["status"], ~w(not_started active completed released canceled)a),
      end_behavior: known(schedule["end_behavior"], ~w(release cancel)a),
      phases: phases,
      current_phase: current && Enum.find_index(phases, &(&1.start_at == time(current))),
      reference: get_in(schedule, ["metadata", @reference]),
      metadata: Map.delete(schedule["metadata"] || %{}, @reference),
      created_at: time(schedule["created"]),
      released_at: time(schedule["released_at"]),
      canceled_at: time(schedule["canceled_at"]),
      completed_at: time(schedule["completed_at"])
    }
    |> Subscription.Schedule.builder()
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
      proration: known(phase["proration_behavior"], ~w(create_prorations always_invoice none)a)
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

  defp credit_line_params(%CreditNote.Lines{invoice_line_id: id} = line) when is_binary(id) do
    %{
      "type" => "invoice_line_item",
      "invoice_line_item" => id,
      "quantity" => line.quantity,
      "amount" => minor_of(line.amount)
    }
    |> reject_nil()
  end

  defp credit_line_params(%CreditNote.Lines{} = line) do
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
      customer_id: customer_ref(note),
      amount: money(note["amount"], currency),
      amount_tax: money(tax_of(note), currency),
      lines:
        note
        |> get_in(["lines", "data"])
        |> List.wrap()
        |> Enum.map(&credit_line(&1, currency)),
      reason:
        known(note["reason"], ~w(duplicate fraudulent order_change product_unsatisfactory)a),
      out_of_band_amount: money(note["out_of_band_amount"], currency),
      memo: blank(note["memo"]),
      number: note["number"],
      status: known(note["status"], ~w(issued void)a),
      type: known(note["type"], ~w(pre_payment post_payment mixed)a),
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
  A Stripe credit note line item as a `MishkaPay.CreditNote.Lines`, in its note's `currency` (the
  line carries none).
  """
  @spec credit_note_line(map(), String.t()) ::
          {:ok, CreditNote.Lines.t()} | {:error, Splode.Error.t()}
  def credit_note_line(line, currency) do
    line
    |> credit_line(currency)
    |> CreditNote.Lines.builder()
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
  @spec change_params(MishkaPay.Subscription.Change.t(), String.t()) :: map()
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
  @spec preview_params(MishkaPay.Subscription.Change.t(), String.t()) :: map()
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

  # Stripe's word as one of the atoms given (written here, so each one exists), or nil.
  defp known(value, atoms) when is_binary(value),
    do: Enum.find(atoms, &(Atom.to_string(&1) == value))

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
  A Stripe event as a `MishkaPay.Event`, with what it is about: a snapshot event (`object:
  "event"`), or a thin one (`object: "v2.core.event"`, as an event destination sends API v2's
  events), whose related object is what it is about and whose `context`, else the account it is
  about, is its `:account`, and whose type is `event_type/1`'s; one a customer made on Accounts v2
  sends (`v2.core.account.updated`, `.closed`, `[identity].updated`,
  `[configuration.customer].*`) names that account as its `:customer_id` too. A saved payment method's or a
  setup's event is about the customer it names (a detached payment method names it in
  `previous_attributes`), since that customer is what changes.
  """
  @spec event(map()) :: {:ok, Event.t()} | {:error, Splode.Error.t()}
  def event(%{"object" => "v2.core.event"} = event) do
    related = event["related_object"] || %{}

    %{
      provider: "stripe",
      id: event["id"],
      type: event_type(event["type"]),
      object_id: related["id"],
      object_type: related["type"],
      livemode: event["livemode"],
      account: event["context"] || account_of(related),
      customer_id: customer_account_of(event["type"], related),
      created_at: time(event["created"])
    }
    |> Event.builder()
    |> MishkaPay.Errors.from_builder()
  end

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

  @doc """
  A thin event of a v1 resource (`v1.invoice.paid`) as the `MishkaPay.Event` its snapshot event
  gives, with its own id, time and `context` (its `:account`) and the snapshot event's type
  (`event_type/1`): its ids are read from
  `object`, the related object as Stripe answers it now, or, left `nil`, from the related object's
  id and type alone; `before` is the full event's `changes.before`, where a detached payment
  method still names its customer.
  """
  @spec thin_event(map(), map() | nil, map() | nil) ::
          {:ok, Event.t()} | {:error, Splode.Error.t()}
  def thin_event(%{"object" => "v2.core.event"} = thin, object, before) do
    related = thin["related_object"] || %{}

    event(%{
      "id" => thin["id"],
      "type" => event_type(thin["type"]),
      "livemode" => thin["livemode"],
      "account" => thin["context"],
      "created" => thin["created"],
      "data" => %{
        "object" => object || %{"id" => related["id"], "object" => related["type"]},
        "previous_attributes" => before
      }
    })
  end

  @doc """
  The type a Stripe event's `MishkaPay.Event` carries: a thin event of a v1 resource is named as
  its snapshot event (`v1.invoice.paid` is `invoice.paid`, `v1.invoice.overpaid` is
  `invoice.overpaid`), so a listener takes either kind by one name; API v2's own events keep
  Stripe's names (`v2.core.account.updated`).
  """
  @spec event_type(String.t()) :: String.t()
  def event_type("v1." <> type), do: type
  def event_type(type), do: type

  # A thin event about a connected account names it only as its related object.
  defp account_of(%{"type" => "v2.core.account", "id" => id}), do: id
  defp account_of(_other), do: nil

  # The account events a customer made on Accounts v2 sends (its email, name, phone, address,
  # invoice default or close) name the customer that account may be; one that is only a seller
  # reads as no customer.
  @customer_account_events ~w(v2.core.account.updated v2.core.account.closed v2.core.account[identity].updated)

  defp customer_account_of("v2.core.account[configuration.customer]." <> _, %{"id" => id}),
    do: id

  defp customer_account_of(type, %{"id" => id}) when type in @customer_account_events, do: id

  defp customer_account_of(_type, _related), do: nil

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
  defp customer_of(_event, %{"object" => "customer", "id" => id} = customer) when is_binary(id),
    do: id_of(customer["customer_account"]) || id

  defp customer_of(event, %{"object" => type} = object)
       when type in ~w(tax_id payment_method setup_intent entitlements.active_entitlement_summary) do
    customer_ref(object) || customer_ref(get_in(event, ["data", "previous_attributes"]) || %{})
  end

  defp customer_of(_event, _other), do: nil

  @dispute_statuses ~w(warning_needs_response warning_under_review warning_closed needs_response under_review won lost prevented)a

  @doc "A Stripe PaymentMethod as a `MishkaPay.Customer.PaymentMethod`, with its card when it is one."
  @spec payment_method(map()) :: {:ok, Customer.PaymentMethod.t()} | {:error, Splode.Error.t()}
  def payment_method(method) do
    card = method["card"] || %{}

    %{
      provider: "stripe",
      id: method["id"],
      customer_id: customer_ref(method),
      type: method["type"],
      card_brand: card["brand"],
      card_last4: card["last4"],
      card_exp_month: card["exp_month"],
      card_exp_year: card["exp_year"],
      created_at: time(method["created"])
    }
    |> Customer.PaymentMethod.builder()
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

  @doc "A Stripe Radar early fraud warning as a `MishkaPay.Payment.FraudWarning`."
  @spec fraud_warning(map()) ::
          {:ok, MishkaPay.Payment.FraudWarning.t()} | {:error, Splode.Error.t()}
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
    |> MishkaPay.Payment.FraudWarning.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @opened_reasons %{"rule" => :rule, "manual" => :manual}

  @doc "A Stripe Radar review as a `MishkaPay.Payment.FraudReview`."
  @spec fraud_review(map()) ::
          {:ok, MishkaPay.Payment.FraudReview.t()} | {:error, Splode.Error.t()}
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
    |> MishkaPay.Payment.FraudReview.builder()
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
  @spec file_params(MishkaPay.File.Upload.t()) :: [{String.t(), term()}]
  def file_params(%MishkaPay.File.Upload{} = upload) do
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
      purpose: known(file["purpose"], ~w(dispute_evidence)a) || :other,
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

  @doc "A Stripe file link as a `MishkaPay.File.Link`."
  @spec file_link(map()) :: {:ok, MishkaPay.File.Link.t()} | {:error, Splode.Error.t()}
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
    |> MishkaPay.File.Link.builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp object_of(%{"data" => %{"object" => %{} = object}}), do: object
  defp object_of(_no_object), do: %{}

  defp expanded(%{} = object), do: object
  defp expanded(_id_or_nil), do: %{}

  defp id_of(%{"id" => id}), do: id
  defp id_of(id) when is_binary(id), do: id
  defp id_of(_none), do: nil

  @doc """
  The parameter that names a customer at Stripe, with its id: `customer_account` for an account
  with the customer configuration (Accounts v2, `acct_...`), `customer` for a Customer
  (`cus_...`). Stripe takes either on every v1 call that names a customer.
  """
  @spec customer_param(String.t() | nil) :: {String.t(), String.t() | nil}
  def customer_param("acct_" <> _ = id), do: {"customer_account", id}
  def customer_param(id), do: {"customer", id}

  defp with_customer(params, nil), do: params

  defp with_customer(params, id) do
    {name, id} = customer_param(id)
    Map.put(params, name, id)
  end

  # The customer an object names: its account when it has one (a customer made on Accounts v2,
  # which Stripe also names by a linked Customer), else its Customer.
  defp customer_ref(object), do: id_of(object["customer_account"]) || id_of(object["customer"])

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
  @spec promotion_code_params(Coupon.PromotionCode.t()) :: map()
  def promotion_code_params(%Coupon.PromotionCode{} = code) do
    %{
      "promotion" => %{"type" => "coupon", "coupon" => code.coupon_id},
      "code" => code.code,
      "active" => code.active,
      "max_redemptions" => code.max_redemptions,
      "expires_at" => code.expires_at && DateTime.to_unix(code.expires_at),
      "restrictions" => restrictions(code),
      "metadata" => code.metadata
    }
    |> with_customer(code.customer_id)
  end

  defp restrictions(%Coupon.PromotionCode{first_time_transaction: first, minimum_amount: minimum}) do
    %{
      "first_time_transaction" => first,
      "minimum_amount" => minimum && minor(minimum),
      "minimum_amount_currency" => minimum && lower_currency(minimum)
    }
  end

  @doc "Params of `POST /v1/promotion_codes/:id`: only whether it is active, and its metadata."
  @spec promotion_code_update_params(Coupon.PromotionCode.t()) :: map()
  def promotion_code_update_params(%Coupon.PromotionCode{} = code),
    do: %{"active" => code.active, "metadata" => code.metadata}

  @doc "A Stripe promotion code as a `MishkaPay.Coupon.PromotionCode`."
  @spec promotion_code(map()) :: {:ok, Coupon.PromotionCode.t()} | {:error, Splode.Error.t()}
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
      customer_id: customer_ref(code),
      metadata: code["metadata"],
      times_redeemed: code["times_redeemed"],
      created_at: time(code["created"])
    }
    |> Coupon.PromotionCode.builder()
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
  defp tax_behavior(behavior) when is_binary(behavior),
    do: known(behavior, ~w(inclusive exclusive)a)

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
      aggregation: known(get_in(meter, ["default_aggregation", "formula"]), ~w(sum count last)a),
      status: known(meter["status"], ~w(active inactive)a),
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

  @doc """
  One event of `POST /v2/billing/meter_event_stream` (JSON): the customer and the value in its
  payload, its `identifier`, and when it happened as an ISO 8601 time.
  """
  @spec usage_event(MishkaPay.Usage.t(), String.t()) :: map()
  def usage_event(usage, identifier) do
    reject_nil(%{
      "event_name" => usage.event_name,
      "identifier" => identifier,
      "payload" => %{
        "stripe_customer_id" => usage.customer_id,
        "value" => usage_value(usage.value)
      },
      "timestamp" => usage.at && DateTime.to_iso8601(usage.at)
    })
  end

  @doc """
  How long a usage value is as Stripe reads it: `{digits, places}`, its digits without leading
  zeros and those after the decimal point, of the value as it is sent (trailing zeros after the
  point dropped).
  """
  @spec usage_size(integer() | Decimal.t()) :: {non_neg_integer(), non_neg_integer()}
  def usage_size(value) do
    [whole | fraction] = value |> usage_value() |> String.trim_leading("-") |> String.split(".")
    places = fraction |> Enum.join() |> String.length()
    {String.length(String.trim_leading(whole, "0")) + places, places}
  end

  # A decimal goes without the zeros that end its fraction: `1.50` is sent as `1.5`.
  defp usage_value(%Decimal{} = value),
    do: value |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp usage_value(value), do: Integer.to_string(value)

  @doc "The usage with Stripe's answer: its `identifier` as the report's id."
  @spec usage(map(), MishkaPay.Usage.t()) :: MishkaPay.Usage.t()
  def usage(answer, usage), do: %{usage | id: answer["identifier"]}

  @doc "Params of `POST /v1/billing/meter_event_adjustments`: cancel the report by its identifier."
  @spec usage_cancellation_params(MishkaPay.Usage.Cancellation.t()) :: map()
  def usage_cancellation_params(cancel) do
    %{
      "event_name" => cancel.event_name,
      "type" => "cancel",
      "cancel" => %{"identifier" => cancel.usage_id}
    }
  end

  @doc "The cancel with Stripe's answer: the adjustment's `status`."
  @spec usage_cancellation(map(), MishkaPay.Usage.Cancellation.t()) ::
          {:ok, MishkaPay.Usage.Cancellation.t()}
  def usage_cancellation(answer, cancel),
    do: {:ok, %{cancel | status: known(answer["status"], ~w(pending complete)a)}}

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
  Stripe's summaries of a window as one `MishkaPay.Usage.Summary`. Asked for without grouping,
  Stripe answers one summary for the whole window, or none when nothing was reported.
  """
  @spec usage_summary(map(), String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, MishkaPay.Usage.Summary.t()} | {:error, Splode.Error.t()}
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
    |> MishkaPay.Usage.Summary.builder()
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

  @doc "A Stripe active entitlement as a `MishkaPay.Feature.Entitlement`."
  @spec entitlement(map()) ::
          {:ok, MishkaPay.Feature.Entitlement.t()} | {:error, Splode.Error.t()}
  def entitlement(entitlement) do
    %{
      provider: "stripe",
      id: entitlement["id"],
      feature_id: id_of(entitlement["feature"]),
      lookup_key: entitlement["lookup_key"]
    }
    |> MishkaPay.Feature.Entitlement.builder()
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

  @doc "A Stripe balance transaction as a `MishkaPay.Balance.Transaction`."
  @spec balance_transaction(map()) ::
          {:ok, MishkaPay.Balance.Transaction.t()} | {:error, Splode.Error.t()}
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
      payment_id: payment_of(txn["source"]),
      status: known(txn["status"], ~w(available pending)a),
      description: txn["description"],
      available_at: time(txn["available_on"]),
      created_at: time(txn["created"])
    }
    |> MishkaPay.Balance.Transaction.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc """
  The balance transactions of a PaymentIntent read with its latest charge's and refunds' balance
  transactions expanded, newest first, each with its source as the object it came from, so it
  names the payment.
  """
  @spec payment_movements(map()) :: [map()]
  def payment_movements(intent) do
    charge = expanded(intent["latest_charge"])
    refunds = get_in(charge, ["refunds", "data"]) || []
    payment = %{"payment_intent" => intent["id"]}

    [charge | refunds]
    |> Enum.flat_map(fn object ->
      case expanded(object["balance_transaction"]) do
        %{"id" => _id} = txn ->
          [Map.put(txn, "source", Map.merge(payment, %{"id" => object["id"]}))]

        _not_read ->
          []
      end
    end)
    |> Enum.sort_by(& &1["created"], :desc)
  end

  @doc """
  Params of `POST /v1/customers/:id/balance_transactions`: the signed amount in Stripe's places
  (below zero is credit), why, and the reference in its metadata.
  """
  @spec customer_balance_params(MishkaPay.Customer.BalanceTransaction.t()) :: map()
  def customer_balance_params(txn) do
    reject_nil(%{
      "amount" => minor(txn.amount),
      "currency" => lower_currency(txn.amount),
      "description" => txn.description,
      "metadata" => txn.reference && %{@reference => txn.reference}
    })
  end

  @doc "A Stripe customer balance transaction as a `MishkaPay.Customer.BalanceTransaction`."
  @spec customer_balance_transaction(map()) ::
          {:ok, MishkaPay.Customer.BalanceTransaction.t()} | {:error, Splode.Error.t()}
  def customer_balance_transaction(txn) do
    currency = txn["currency"]

    %{
      provider: "stripe",
      id: txn["id"],
      customer_id: customer_ref(txn),
      amount: signed_money(txn["amount"], currency),
      ending_balance: signed_money(txn["ending_balance"], currency),
      type: txn["type"],
      description: txn["description"],
      invoice_id: id_of(txn["invoice"]),
      reference: get_in(txn, ["metadata", @reference]),
      created_at: time(txn["created"])
    }
    |> MishkaPay.Customer.BalanceTransaction.builder()
    |> MishkaPay.Errors.from_builder()
  end

  # What each configuration asks for when an account is made: Accounts v2 nests it under its
  # configuration, Accounts v1 names the same capability plainly.
  @asked %{
    merchant: {["card_payments"], "card_payments"},
    recipient: {["stripe_balance", "stripe_transfers"], "transfers"},
    customer: {[], nil}
  }
  @everything ~w(configuration.merchant configuration.recipient configuration.customer requirements defaults identity)

  @doc "What a v2 account read includes: its configurations, requirements, defaults and identity."
  @spec account_includes() :: [String.t()]
  def account_includes, do: @everything

  @doc """
  Params of making a connected account: `POST /v2/core/accounts` (`:v2`), with its dashboard,
  configurations and who collects fees and losses; or `POST /v1/accounts` (`:v1`), with the
  matching `controller` and capabilities. Either keeps the reference in its metadata.
  """
  @spec connected_account_params(MishkaPay.ConnectedAccount.t(), :v2 | :v1) :: map()
  def connected_account_params(account, api) do
    made = %{
      account
      | dashboard: account.dashboard || :express,
        configurations: account.configurations || [:merchant, :recipient]
    }

    made
    |> connected_account_update_params(api)
    |> Map.merge(account_shape(made, api))
  end

  defp account_shape(account, :v2) do
    reject_nil(%{
      "dashboard" => Atom.to_string(account.dashboard),
      "identity" => account.country && %{"country" => account.country},
      "defaults" => %{
        "responsibilities" => %{
          "fees_collector" => Atom.to_string(collector(account, :fees_collector)),
          "losses_collector" => Atom.to_string(collector(account, :losses_collector))
        }
      }
    })
  end

  defp account_shape(account, :v1) do
    controller =
      reject_nil(%{
        "stripe_dashboard" => %{"type" => Atom.to_string(account.dashboard)},
        "fees" => keyed("payer", v1_collector(account, :fees_collector, "account")),
        "losses" => keyed("payments", v1_collector(account, :losses_collector, "stripe")),
        "requirement_collection" => requirement_collection(account.dashboard)
      })

    reject_nil(%{"controller" => controller, "country" => account.country})
  end

  # An account with no dashboard of its own has the platform collect its details.
  defp requirement_collection(:none), do: "application"
  defp requirement_collection(_dashboard), do: nil

  # Stripe's own default for each dashboard: the platform answers for an Express account and an
  # account with no dashboard, the seller with Stripe for a full one.
  defp collector(%{dashboard: :full} = account, field), do: Map.get(account, field) || :stripe
  defp collector(account, field), do: Map.get(account, field) || :application

  # Who collects, as v1's controller says it: the platform always; the seller with Stripe only
  # when asked for, since that is Stripe's own default for a full dashboard.
  defp v1_collector(account, field, seller_word),
    do: v1_word(Map.get(account, field), collector(account, field), seller_word)

  defp v1_word(_given, :application, _seller_word), do: "application"
  defp v1_word(:stripe, :stripe, seller_word), do: seller_word
  defp v1_word(nil, :stripe, _seller_word), do: nil

  defp keyed(_key, nil), do: nil
  defp keyed(key, value), do: %{key => value}

  @doc """
  Params of changing a connected account (`POST /v2/core/accounts/:id` or `POST
  /v1/accounts/:id`): only the details given, and the configurations and capabilities given
  added to the account's.
  """
  @spec connected_account_update_params(MishkaPay.ConnectedAccount.t(), :v2 | :v1) :: map()
  def connected_account_update_params(account, :v2) do
    reject_nil(%{
      "contact_email" => account.email,
      "display_name" => account.business_name,
      "configuration" => v2_configuration(account),
      "metadata" => with_reference(account.metadata, account.reference),
      "include" => @everything
    })
  end

  def connected_account_update_params(account, :v1) do
    reject_nil(%{
      "email" => account.email,
      "business_profile" => account.business_name && %{"name" => account.business_name},
      "capabilities" => v1_capabilities(account),
      "metadata" => with_reference(account.metadata, account.reference)
    })
  end

  defp v2_configuration(%{configurations: nil, capabilities: nil}), do: nil

  defp v2_configuration(account) do
    asked =
      account.configurations
      |> List.wrap()
      |> Enum.reduce(%{}, fn name, acc ->
        {path, _v1} = @asked[name]
        requested(acc, [Atom.to_string(name) | path])
      end)

    account.capabilities
    |> List.wrap()
    |> Enum.reduce(asked, &requested(&2, String.split(&1, ".")))
    |> Map.new(fn {name, capabilities} -> {name, configuration_of(capabilities)} end)
  end

  # A configuration with nothing asked of it is applied as it is.
  defp requested(acc, [name]), do: Map.put_new(acc, name, %{})

  defp requested(acc, [name | path]),
    do:
      update_in(
        acc,
        [Access.key(name, %{})],
        &put_in(&1, Enum.map(path, fn key -> Access.key(key, %{}) end), %{"requested" => true})
      )

  defp configuration_of(capabilities) when map_size(capabilities) == 0, do: %{}
  defp configuration_of(capabilities), do: %{"capabilities" => capabilities}

  defp v1_capabilities(%{configurations: nil, capabilities: nil}), do: nil

  defp v1_capabilities(account) do
    names =
      Enum.flat_map(List.wrap(account.configurations), fn name ->
        {_path, v1} = @asked[name]
        List.wrap(v1)
      end) ++ List.wrap(account.capabilities)

    Map.new(names, &{&1, %{"requested" => true}})
  end

  @capability_states ~w(active pending restricted rejected unsupported inactive)a
  @v1_dashboards %{"express" => :express, "standard" => :full, "custom" => :none}

  @doc """
  A Stripe connected account as a `MishkaPay.ConnectedAccount`, read with either API: a
  `v2.core.account` with its configurations' capabilities and the requirements the seller must
  meet, or a v1 `account` with its controller and capabilities.
  """
  @spec connected_account(map()) ::
          {:ok, MishkaPay.ConnectedAccount.t()} | {:error, Splode.Error.t()}
  def connected_account(%{"object" => "v2.core.account"} = account) do
    states = v2_states(account["configuration"] || %{})
    requirements = account["requirements"]
    responsibilities = get_in(account, ["defaults", "responsibilities"]) || %{}

    account
    |> account_common()
    |> Map.merge(%{
      api: :v2,
      dashboard: known(account["dashboard"], ~w(express full none)a),
      configurations:
        Enum.map(
          account["applied_configurations"] || [],
          &known(&1, ~w(merchant recipient customer)a)
        ),
      fees_collector: known(responsibilities["fees_collector"], ~w(application stripe)a),
      losses_collector: known(responsibilities["losses_collector"], ~w(application stripe)a),
      country: get_in(account, ["identity", "country"]),
      email: account["contact_email"],
      business_name: account["display_name"],
      capabilities: Map.keys(states),
      capability_status:
        Map.new(states, fn {name, state} -> {name, known(state["status"], @capability_states)} end),
      charges_enabled: active?(states, ["merchant.card_payments"]),
      payouts_enabled:
        active?(states, ["merchant.stripe_balance.payouts", "recipient.stripe_balance.payouts"]),
      transfers_enabled: active?(states, ["recipient.stripe_balance.stripe_transfers"]),
      details_submitted:
        is_map(requirements) and
          due(requirements, ~w(currently_due past_due eventually_due)) == [],
      requirements_due: due(requirements, ~w(currently_due past_due)),
      disabled_reason: held_back(states),
      default_currency: get_in(account, ["defaults", "currency"]),
      closed: account["closed"] == true,
      created_at: time(account["created"])
    })
    |> built_account()
  end

  def connected_account(account) do
    states = account["capabilities"] || %{}
    controller = account["controller"] || %{}
    disabled = get_in(account, ["requirements", "disabled_reason"])

    account
    |> account_common()
    |> Map.merge(%{
      api: :v1,
      dashboard:
        known(get_in(controller, ["stripe_dashboard", "type"]), ~w(express full none)a) ||
          @v1_dashboards[account["type"]],
      configurations:
        for(
          {name, capability} <- [merchant: "card_payments", recipient: "transfers"],
          is_map_key(states, capability),
          do: name
        ),
      fees_collector: v1_payer(get_in(controller, ["fees", "payer"])),
      losses_collector:
        known(get_in(controller, ["losses", "payments"]), ~w(application stripe)a),
      country: account["country"],
      email: account["email"],
      business_name: get_in(account, ["business_profile", "name"]),
      capabilities: Map.keys(states),
      capability_status:
        Map.new(states, fn {name, state} -> {name, known(state, @capability_states)} end),
      charges_enabled: account["charges_enabled"] == true,
      payouts_enabled: account["payouts_enabled"] == true,
      transfers_enabled: states["transfers"] == "active",
      details_submitted: account["details_submitted"] == true,
      requirements_due: get_in(account, ["requirements", "currently_due"]) || [],
      disabled_reason: disabled,
      default_currency: account["default_currency"],
      closed: is_binary(disabled) and String.starts_with?(disabled, "rejected."),
      created_at: time(account["created"])
    })
    |> built_account()
  end

  defp account_common(account) do
    metadata = account["metadata"] || %{}

    %{
      provider: "stripe",
      id: account["id"],
      reference: metadata[@reference],
      metadata: Map.delete(metadata, @reference)
    }
  end

  defp built_account(attrs) do
    attrs
    |> reject_nil()
    |> MishkaPay.ConnectedAccount.builder()
    |> MishkaPay.Errors.from_builder()
  end

  # Accounts v1 says who pays Stripe's fees: the connected account itself (with Stripe), or the
  # platform under one of its names.
  defp v1_payer("account"), do: :stripe
  defp v1_payer("application" <> _kind), do: :application
  defp v1_payer(_none), do: nil

  # Each capability of each configuration, by its dotted name (`"merchant.card_payments"`,
  # `"recipient.stripe_balance.stripe_transfers"`); one Stripe never asked for is `null`.
  defp v2_states(configuration) do
    for {name, %{"capabilities" => %{} = capabilities}} <- configuration,
        state <- leaves(capabilities, [name]),
        into: %{},
        do: state
  end

  defp leaves(%{"status" => _status} = state, path), do: [{Enum.join(path, "."), state}]

  defp leaves(%{} = nested, path),
    do: Enum.flat_map(nested, fn {key, value} -> leaves(value, path ++ [key]) end)

  defp leaves(_null, _path), do: []

  defp active?(states, names), do: Enum.any?(names, &(get_in(states, [&1, "status"]) == "active"))

  # What the seller still has to give: the entries awaiting them, by how soon they are due.
  defp due(%{"entries" => entries}, deadlines) when is_list(entries) do
    for %{"awaiting_action_from" => "user", "description" => what} = entry <- entries,
        get_in(entry, ["minimum_deadline", "status"]) in deadlines,
        do: what
  end

  defp due(_none, _deadlines), do: []

  # Why a capability is held back, as Stripe words it (`requirements_past_due`, `rejected_fraud`).
  defp held_back(states) do
    Enum.find_value(states, fn
      {_name, %{"status" => status, "status_details" => [%{"code" => code} | _]}}
      when status in ~w(restricted rejected unsupported) ->
        code

      _active_or_pending ->
        nil
    end)
  end

  @link_types %{onboarding: "account_onboarding", update: "account_update"}

  @doc """
  Params of an account link: `POST /v2/core/account_links` (`:v2`), its use case with the two
  pages; or `POST /v1/account_links` (`:v1`).
  """
  @spec account_link_params(MishkaPay.ConnectedAccount.Link.t(), :v2 | :v1) :: map()
  def account_link_params(link, :v2) do
    type = @link_types[link.type]

    %{
      "account" => link.account_id,
      "use_case" => %{
        "type" => type,
        type => %{"refresh_url" => link.refresh_url, "return_url" => link.return_url}
      }
    }
  end

  def account_link_params(link, :v1) do
    %{
      "account" => link.account_id,
      "type" => @link_types[link.type],
      "refresh_url" => link.refresh_url,
      "return_url" => link.return_url
    }
  end

  @doc "A Stripe account link or login link as the `MishkaPay.ConnectedAccount.Link` asked for, with its URL."
  @spec account_link(map(), MishkaPay.ConnectedAccount.Link.t()) ::
          {:ok, MishkaPay.ConnectedAccount.Link.t()} | {:error, Splode.Error.t()}
  def account_link(answer, link) do
    made = %{
      link
      | url: answer["url"],
        expires_at: time(answer["expires_at"]),
        created_at: time(answer["created"])
    }

    {:ok, made}
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

  @doc "A Stripe Payout as a `MishkaPay.Balance.Payout`."
  @spec payout(map()) :: {:ok, MishkaPay.Balance.Payout.t()} | {:error, Splode.Error.t()}
  def payout(payout) do
    metadata = payout["metadata"] || %{}

    %{
      provider: "stripe",
      id: payout["id"],
      reference: metadata[@reference],
      metadata: Map.delete(metadata, @reference),
      statement_descriptor: payout["statement_descriptor"],
      amount: money(payout["amount"], payout["currency"]),
      status: known(payout["status"], ~w(pending in_transit paid failed canceled)a),
      arrival_at: time(payout["arrival_date"]),
      automatic: payout["automatic"] == true,
      method: payout["method"],
      destination_id: id_of(payout["destination"]),
      failure_code: payout["failure_code"],
      failure_message: payout["failure_message"],
      description: payout["description"],
      created_at: time(payout["created"])
    }
    |> MishkaPay.Balance.Payout.builder()
    |> MishkaPay.Errors.from_builder()
  end

  @doc """
  Params of `POST /v1/payouts`: the amount in Stripe's places, and what the payout gives; its
  reference goes in its metadata.
  """
  @spec payout_params(MishkaPay.Balance.Payout.t()) :: map()
  def payout_params(payout) do
    reject_nil(%{
      "amount" => minor(payout.amount),
      "currency" => lower_currency(payout.amount),
      "method" => payout.method,
      "destination" => payout.destination_id,
      "statement_descriptor" => payout.statement_descriptor,
      "description" => payout.description,
      "metadata" => with_reference(payout.metadata, payout.reference)
    })
  end

  @weekdays ~w(monday tuesday wednesday thursday friday)a

  @doc """
  Stripe's Balance Settings as a `MishkaPay.Balance.PayoutSchedule`: the payouts' schedule, the
  delay of a payment's money (`settlement_timing.delay_days`, the override when set), the money
  kept per currency and the statement descriptor.
  """
  @spec payout_schedule(map()) ::
          {:ok, MishkaPay.Balance.PayoutSchedule.t()} | {:error, Splode.Error.t()}
  def payout_schedule(settings) do
    payouts = get_in(settings, ["payments", "payouts"]) || %{}
    schedule = payouts["schedule"] || %{}
    timing = get_in(settings, ["payments", "settlement_timing"]) || %{}

    %{
      provider: "stripe",
      interval: known(schedule["interval"], ~w(manual daily weekly monthly)a),
      weekly_days:
        schedule["weekly_payout_days"] &&
          Enum.flat_map(schedule["weekly_payout_days"], &List.wrap(known(&1, @weekdays))),
      monthly_days: schedule["monthly_payout_days"],
      delay_days: timing["delay_days_override"] || timing["delay_days"],
      minimum_balances: by_currency(payouts["minimum_balance_by_currency"]),
      statement_descriptor: payouts["statement_descriptor"],
      status: known(payouts["status"], ~w(enabled disabled)a),
      minimum_payouts: []
    }
    |> MishkaPay.Balance.PayoutSchedule.builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp by_currency(%{} = amounts) do
    for {currency, minor} <- amounts, money = money(minor, currency), do: money
  end

  defp by_currency(_none), do: []

  @doc """
  Params of `POST /v1/balance_settings`: only what the schedule gives. `delay_days: :default`
  clears the override (Stripe's empty value), and `minimum_balances: []` keeps nothing back.
  """
  @spec payout_schedule_params(MishkaPay.Balance.PayoutSchedule.t()) :: map()
  def payout_schedule_params(schedule) do
    plan =
      reject_nil(%{
        "interval" => schedule.interval && Atom.to_string(schedule.interval),
        "weekly_payout_days" =>
          schedule.weekly_days && Enum.map(schedule.weekly_days, &to_string/1),
        "monthly_payout_days" => schedule.monthly_days
      })

    payouts =
      reject_nil(%{
        "schedule" => if(plan != %{}, do: plan),
        "minimum_balance_by_currency" => minimum_balances(schedule.minimum_balances),
        "statement_descriptor" => schedule.statement_descriptor
      })

    timing = reject_nil(%{"delay_days_override" => delay_override(schedule.delay_days)})

    payments =
      reject_nil(%{
        "payouts" => if(payouts != %{}, do: payouts),
        "settlement_timing" => if(timing != %{}, do: timing)
      })

    %{"payments" => payments}
  end

  defp minimum_balances(nil), do: nil
  defp minimum_balances([]), do: ""

  defp minimum_balances(list),
    do: Map.new(list, fn money -> {lower_currency(money), minor(money)} end)

  defp delay_override(:default), do: ""
  defp delay_override(days), do: days

  @doc "A Stripe external account (a bank account or a card) as a `MishkaPay.Balance.PayoutDestination`."
  @spec payout_destination(map()) ::
          {:ok, MishkaPay.Balance.PayoutDestination.t()} | {:error, Splode.Error.t()}
  def payout_destination(account) do
    %{
      provider: "stripe",
      id: account["id"],
      type: known(account["object"], ~w(bank_account card)a),
      bank_name: account["bank_name"],
      card_brand: account["brand"],
      last4: account["last4"],
      currency: account["currency"],
      country: account["country"],
      default: account["default_for_currency"] == true,
      holder_name: account["account_holder_name"] || account["name"],
      status: account["status"]
    }
    |> MishkaPay.Balance.PayoutDestination.builder()
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

  # API v2 answers times in RFC 3339 (`"2026-11-17T11:27:06.000Z"`).
  defp time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, time, _offset} -> DateTime.truncate(time, :second)
      {:error, _not_a_time} -> nil
    end
  end

  defp time(_none), do: nil
end

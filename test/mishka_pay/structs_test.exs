# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.StructsTest do
  use ExUnit.Case, async: true

  alias MishkaPay.{
    Balance,
    Checkout,
    Client,
    ConnectedAccount,
    Coupon,
    Credentials,
    CreditNote,
    Customer,
    Dispute,
    Feature,
    File,
    Invoice,
    Payment,
    PortalSession,
    Price,
    RawRequest,
    ShippingRate,
    Subscription,
    TaxCalculation,
    TaxSettings,
    Usage
  }

  @eur %{amount: "10.00", currency: "EUR"}
  @at ~U[2026-11-18 10:00:00Z]

  # Each struct that lives in its parent's file: attrs it takes, and one field it refuses.
  @nested [
    {Balance.Transaction, %{provider: "stripe", id: "txn_1", amount: @eur, status: :available},
     :status, :settled},
    {Balance.Payout, %{provider: "stripe", id: "po_1", amount: @eur, status: :paid}, :id, ""},
    {Customer.BalanceTransaction,
     %{provider: "stripe", customer_id: "cus_1", amount: %{amount: "-5.00", currency: "EUR"}},
     :customer_id, " "},
    {Customer.TaxId, %{provider: "stripe", customer_id: "cus_1", type: "eu_vat", value: "DE1"},
     :type, "EU-VAT"},
    {Customer.PaymentMethod, %{provider: "stripe", id: "pm_1", card_last4: "4242"},
     :card_exp_month, "twelve"},
    {File.Link, %{provider: "stripe", id: "link_1", url: "https://files.test/x"}, :url, ""},
    {File.Upload,
     %{
       provider: "stripe",
       purpose: :dispute_evidence,
       filename: "receipt.pdf",
       content_type: "application/pdf",
       content: "%PDF"
     }, :filename, "../receipt.pdf"},
    {Usage.Summary, %{provider: "stripe", meter_id: "mtr_1", from: @at, to: @at}, :from, "today"},
    {Usage.Cancellation, %{provider: "stripe", event_name: "api_call", usage_id: "u-1"},
     :usage_id, ""},
    {Payment.FraudReview, %{provider: "stripe", id: "prv_1", opened_reason: :rule},
     :opened_reason, :hunch},
    {Payment.FraudWarning, %{provider: "stripe", id: "issfr_1", actionable: true}, :actionable,
     "yes"},
    {Feature.Entitlement, %{provider: "stripe", feature_id: "feat_1", lookup_key: "seats"},
     :lookup_key, 7},
    {Dispute.Evidence,
     %{provider: "stripe", dispute_id: "dp_1", evidence: %{"product_description" => "An ebook"}},
     :evidence, %{"receipt" => 1}},
    {ConnectedAccount.Link,
     %{
       provider: "stripe",
       account_id: "acct_1",
       type: :onboarding,
       refresh_url: "https://shop.test/again",
       return_url: "https://shop.test/done"
     }, :return_url, "http://shop.test/done"},
    {Coupon.PromotionCode, %{provider: "stripe", coupon_id: "SPRING", code: "SPRING10"},
     :max_redemptions, 0},
    {Invoice.Draft, %{provider: "stripe", customer_id: "cus_1", items: [%{id: "price_1"}]},
     :days_until_due, 0},
    {Invoice.Item, %{provider: "stripe", customer_id: "cus_1", price_id: "price_1"}, :quantity,
     0},
    {Subscription.Change, %{provider: "stripe", subscription_id: "sub_1", quantity: 3}, :quantity,
     0},
    {Subscription.Schedule, %{provider: "stripe", subscription_id: "sub_1"}, :end_behavior,
     :forever},
    {PortalSession.Configuration, %{provider: "stripe", name: "Teams"}, :headline,
     String.duplicate("x", 61)},
    {TaxCalculation.Transaction, %{provider: "stripe", id: "tax_1", calculation_id: "taxcalc_1"},
     :posted_at, "now"},
    {TaxSettings.Registration, %{provider: "stripe", country: "de", type: "standard"}, :country,
     "DEU"}
  ]

  describe "a struct kept in its parent's file" do
    test "builds from the attrs it takes, as its own struct" do
      for {module, attrs, _field, _bad} <- @nested do
        assert {:ok, %^module{}} = module.builder(attrs), inspect(module)
      end
    end

    test "refuses a bad value of one of its fields, on that field" do
      for {module, attrs, field, bad} <- @nested do
        assert {:error, errors} = module.builder(Map.put(attrs, field, bad)), inspect(module)
        assert Enum.any?(errors, &(&1.field == field)), inspect({module, errors})
      end
    end

    test "refuses a field it does not have" do
      for {module, attrs, _field, _bad} <- @nested do
        assert {:error, [%{action: :authorized_fields, field: :nope}]} =
                 module.builder(Map.put(attrs, :nope, 1)),
               inspect(module)
      end
    end
  end

  describe "a list sub_field" do
    test "a credit note's lines are CreditNote.Lines, checked one by one" do
      assert {:ok, %CreditNote{lines: [%CreditNote.Lines{invoice_line_id: "il_1", quantity: 1}]}} =
               CreditNote.builder(%{
                 provider: "stripe",
                 invoice_id: "in_1",
                 lines: [%{"invoice_line_id" => " il_1 ", "quantity" => 1}]
               })

      assert {:error, errors} =
               CreditNote.builder(%{
                 provider: "stripe",
                 invoice_id: "in_1",
                 lines: [%{name: "x"}]
               })

      assert Enum.any?(
               errors,
               &match?(%{field: :lines, errors: [%{action: :credit_note_line}]}, &1)
             )

      assert {:error, errors} =
               CreditNote.builder(%{
                 provider: "stripe",
                 invoice_id: "in_1",
                 lines: [%{invoice_line_id: "il_1", quantity: 0}]
               })

      assert Enum.any?(errors, &match?(%{field: :lines, errors: [%{field: :quantity}]}, &1))

      assert {:ok, %CreditNote.Lines{type: :custom}} =
               CreditNote.Lines.builder(%{id: "cnli_1", type: :custom})
    end

    test "an invoice's lines are Invoice.Lines, and a bill without lines has none" do
      assert {:ok, %Invoice{lines: [%Invoice.Lines{price_id: "price_1", proration: true}]}} =
               Invoice.builder(%{
                 provider: "stripe",
                 id: "in_1",
                 lines: [%{price_id: "price_1", proration: true}]
               })

      assert {:ok, %Invoice{lines: []}} = Invoice.builder(%{provider: "stripe", id: "in_1"})

      assert {:error, [%{field: :lines, errors: [%{field: :proration}]}]} =
               Invoice.builder(%{provider: "stripe", id: "in_1", lines: [%{proration: "yes"}]})
    end

    test "a tax calculation's items are TaxCalculation.Items, and it needs them" do
      assert {:ok,
              %TaxCalculation{items: [%TaxCalculation.Items{reference: "sku-1", quantity: 1}]}} =
               TaxCalculation.builder(%{
                 provider: "stripe",
                 customer_id: "cus_1",
                 items: [%{reference: "sku-1", amount: @eur}]
               })

      assert {:error, errors} = TaxCalculation.builder(%{provider: "stripe", customer_id: "c"})
      assert Enum.any?(errors, &(&1.field == :items))

      assert {:error, errors} =
               TaxCalculation.builder(%{
                 provider: "stripe",
                 customer_id: "cus_1",
                 items: [%{reference: "sku-1", amount: @eur, quantity: 0}]
               })

      assert Enum.any?(errors, &match?(%{field: :items, errors: [%{field: :quantity}]}, &1))
    end

    test "a schedule's phases are Subscription.Schedule.Phases, each with prices by id" do
      assert {:ok,
              %Subscription.Schedule{
                phases: [%Subscription.Schedule.Phases{iterations: 12, interval: :month}]
              }} =
               Subscription.Schedule.builder(%{
                 provider: "stripe",
                 customer_id: "cus_1",
                 phases: [%{items: [%{id: "price_1"}], iterations: 12, interval: "month"}]
               })

      assert {:error, [%{field: :phases, errors: [%{action: :subscription_phase}]}]} =
               Subscription.Schedule.builder(%{
                 provider: "stripe",
                 customer_id: "cus_1",
                 phases: [%{items: [%{id: "price_1"}], iterations: 12}]
               })
    end

    test "a portal configuration's plans are Configuration.Plans, each with its price ids" do
      config = %{provider: "stripe", name: "Teams"}

      assert {:ok,
              %PortalSession.Configuration{
                plans: [%PortalSession.Configuration.Plans{price_ids: ["price_a"]}]
              }} =
               PortalSession.Configuration.builder(
                 Map.put(config, :plans, [%{product_id: "prod_1", price_ids: ["price_a"]}])
               )

      for price_ids <- [[], [""], [1], "price_a"] do
        attrs = Map.put(config, :plans, [%{product_id: "prod_1", price_ids: price_ids}])

        assert {:error, [%{field: :plans, errors: [%{field: :price_ids} | _]}]} =
                 PortalSession.Configuration.builder(attrs),
               inspect(price_ids)
      end
    end

    test "a checkout's discounts are Checkout.Discounts, a coupon or a code, not both" do
      base = %{provider: "acme", items: [%{name: "Ebook", amount: @eur}]}

      assert {:ok, %Checkout{discounts: [%Checkout.Discounts{coupon_id: "SPRING"}]}} =
               Checkout.builder(Map.put(base, :discounts, [%{coupon_id: "SPRING"}]))

      for discount <- [%{}, %{coupon_id: "SPRING", promotion_code_id: "promo_1"}] do
        assert {:error, [%{field: :discounts, errors: [%{action: :discount}]}]} =
                 Checkout.builder(Map.put(base, :discounts, [discount]))
      end
    end

    test "a checkout's fields are Checkout.Fields, at most three, a dropdown with its Options" do
      base = %{provider: "acme", items: [%{name: "Ebook", amount: @eur}]}

      dropdown = %{
        key: "plan",
        label: "Plan",
        type: "dropdown",
        options: [%{value: "pro", label: "Pro"}]
      }

      assert {:ok,
              %Checkout{
                fields: [
                  %Checkout.Fields{
                    type: :dropdown,
                    options: [%Checkout.Fields.Options{value: "pro", label: "Pro"}]
                  }
                ]
              }} = Checkout.builder(Map.put(base, :fields, [dropdown]))

      text = %{key: "site", label: "Site"}

      for {fields, field} <- [
            {[text, text, text, text], :fields},
            {[%{dropdown | options: []}], :options},
            {[Map.put(text, :options, [%{value: "a", label: "A"}])], :options},
            {[%{dropdown | options: [%{value: "pro"}]}], :label},
            {[%{text | key: "my site"}], :key}
          ] do
        assert {:error, errors} = Checkout.builder(Map.put(base, :fields, fields))
        assert field in fields_of(errors), inspect({fields, errors})
      end
    end

    test "a raw request's options are RawRequest.Options, and never a header" do
      call = %{provider: "stripe", path: "/v1/balance"}

      assert {:ok, %RawRequest{options: %RawRequest.Options{expand: ["data.customer"]}}} =
               RawRequest.builder(Map.put(call, :options, %{expand: ["data.customer"]}))

      for options <- [
            %{api_version: "2026-10-28\r\nAuthorization: x"},
            %{expand: ["a.b.c.d.e"]},
            %{expand: Enum.map(1..21, &"f#{&1}")},
            %{headers: %{"authorization" => "x"}}
          ] do
        assert {:error, [%{field: :options}]} =
                 RawRequest.builder(Map.put(call, :options, options)),
               inspect(options)
      end
    end

    test "a value of the wrong shape is refused, never kept unbuilt" do
      assert {:error, errors} =
               CreditNote.builder(%{provider: "stripe", invoice_id: "in_1", lines: "il_1"})

      assert Enum.any?(errors, &(&1.field == :lines))

      assert {:error, [%{field: :options}]} =
               RawRequest.builder(%{provider: "stripe", path: "/v1/x", options: "expand"})

      assert {:error, [%{field: :customer}]} =
               Checkout.builder(%{
                 provider: "acme",
                 items: [%{name: "Ebook", amount: @eur}],
                 customer: "cus_1"
               })
    end
  end

  describe "a checkout's shipping rates" do
    @base %{provider: "acme", items: [%{name: "Ebook", amount: @eur}]}

    test "take a kept rate's id as a string and a new rate as a ShippingRate" do
      assert {:ok, %Checkout{shipping_rates: ["shr_1", %ShippingRate{name: "Post"}]}} =
               Checkout.builder(
                 Map.put(@base, :shipping_rates, [" shr_1 ", %{name: "Post", amount: @eur}])
               )
    end

    test "refuse an entry that is neither, and anything but a list" do
      for rates <- [[%{name: "Post"}], [1], [""], "shr_1"] do
        assert {:error, [%{field: :shipping_rates} | _]} =
                 Checkout.builder(Map.put(@base, :shipping_rates, rates)),
               inspect(rates)
      end
    end
  end

  describe "a free-form map (dynamic_field)" do
    test "keeps a caller's or provider's keys as strings, even when the atom exists" do
      unseen = "unseen_key_#{System.unique_integer([:positive])}"
      metadata = %{"name" => "Ada", unseen => "1"}

      assert {:ok, %Customer{metadata: ^metadata}} =
               Customer.builder(%{provider: "stripe", metadata: metadata})

      assert {:ok, %Checkout{field_values: %{"name" => "Ada"}}} =
               Checkout.builder(Map.put(@base, :field_values, %{"name" => "Ada"}))

      assert {:ok, %ConnectedAccount{capability_status: %{"merchant.card_payments" => :active}}} =
               ConnectedAccount.builder(%{
                 provider: "stripe",
                 capability_status: %{"merchant.card_payments" => :active}
               })

      params = %{"metadata" => %{"name" => "a"}, "limit" => 3}

      assert {:ok, %RawRequest{params: ^params}} =
               RawRequest.builder(%{provider: "stripe", path: "/v1/x", params: params})

      assert_raise ArgumentError, fn -> String.to_existing_atom(unseen) end
    end

    test "the client sends headers and bodies as given" do
      request = %{provider: "stripe", base_url: "https://api.stripe.test", path: "/v1/x"}

      assert {:ok,
              %Client{
                headers: %{"stripe-version" => "v"},
                form: %{"metadata" => %{"name" => "a"}}
              }} =
               Client.builder(
                 Map.merge(request, %{
                   headers: %{"stripe-version" => "v"},
                   form: %{"metadata" => %{"name" => "a"}}
                 })
               )

      assert {:ok, %Client{json: [%{"op" => "replace"}], params: %{"name" => "a"}}} =
               Client.builder(
                 Map.merge(request, %{json: [%{"op" => "replace"}], params: %{"name" => "a"}})
               )

      assert {:error, [%{field: :json} | _]} =
               Client.builder(%{
                 provider: "stripe",
                 base_url: "https://a.test",
                 path: "/x",
                 json: 1
               })
    end

    test "metadata values must be strings" do
      assert {:error, [%{field: :metadata}]} =
               Customer.builder(%{provider: "stripe", metadata: %{"a" => 1}})
    end
  end

  describe "lists checked by their derives" do
    test "tax rate ids are trimmed, non-empty strings" do
      assert {:ok, %Price{tax_rate_ids: ["txr_1"]}} =
               Price.builder(%{id: "price_1", tax_rate_ids: [" txr_1 "]})

      assert {:error, [%{field: :tax_rate_ids} | _]} =
               Price.builder(%{id: "price_1", tax_rate_ids: [" "]})
    end

    test "capabilities are dotted lowercase names" do
      assert {:ok, %ConnectedAccount{capabilities: ["merchant.card_payments"]}} =
               ConnectedAccount.builder(%{
                 provider: "stripe",
                 capabilities: ["merchant.card_payments"]
               })

      for names <- [["Card"], ["card\n"], [1]] do
        assert {:error, [%{field: :capabilities} | _]} =
                 ConnectedAccount.builder(%{provider: "stripe", capabilities: names})
      end
    end

    test "shipping countries are two letters, upper case" do
      assert {:ok, %Checkout{shipping_countries: ["NL", "DE"]}} =
               Checkout.builder(Map.put(@base, :shipping_countries, ["nl", " de"]))

      for countries <- [["NLD"], [], ["N1"]] do
        assert {:error, [%{field: :shipping_countries} | _]} =
                 Checkout.builder(Map.put(@base, :shipping_countries, countries))
      end
    end

    test "an account id is letters, digits and underscores, so it can never end a header" do
      keys = %{provider: "stripe", secret_key: "sk_test_1"}

      assert {:ok, %Credentials{account_id: "acct_1"}} =
               Credentials.builder(Map.put(keys, :account_id, " acct_1 "))

      for id <- ["acct_1\r\nx: y", "acct 1", ""] do
        assert {:error, [%{field: :account_id}]} =
                 Credentials.builder(Map.put(keys, :account_id, id))
      end
    end
  end

  # Every field an error names, its nested errors' fields too.
  defp fields_of(errors),
    do: Enum.flat_map(errors, &[&1.field | fields_of(Map.get(&1, :errors, []))])
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPayTest do
  # Starts provider and gate plugins, which change events every test sees.
  use ExUnit.Case, async: false

  alias MishkaPay.{Checkout, Errors, Payment, Refund}
  alias MishkaPay.Support.{Acme, CheckoutOnly, StockGate}

  @checkout %{
    provider: "acme",
    tenant: "site-a",
    items: [%{name: "Ebook", amount: %{amount: "19.99", currency: "USD"}}],
    success_url: "https://shop.test/thanks",
    cancel_url: "https://shop.test/cart",
    reference: "order-1"
  }

  setup do
    MishkaPay.Test.start_plugin!(Acme)
    MishkaPay.Test.put_keys("acme", %{secret_key: "sk_acme"})
    ref = :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :checkout, :stop]])
    %{ref: ref}
  end

  test "a checkout reaches the provider with the tenant's keys and comes back with its page", %{
    ref: ref
  } do
    assert {:ok,
            %Checkout{id: "acme_cs_order-1", url: "https://pay.acme.test/order-1", status: :open}} =
             MishkaPay.checkout(@checkout)

    assert_received {[:mishka_pay, :checkout, :stop], ^ref, _,
                     %{provider: "acme", tenant: "site-a", outcome: :ok}}
  end

  test "a declined checkout is a provider error, and telemetry says so", %{ref: ref} do
    assert {:error, %Errors.Declined{reason: "card_declined"}} =
             MishkaPay.checkout(%{@checkout | reference: "decline"})

    assert_received {[:mishka_pay, :checkout, :stop], ^ref, _, %{outcome: :provider}}
  end

  test "a checkout that is not valid never reaches the provider" do
    assert {:error, %Errors.Invalid{}} = MishkaPay.checkout(%{@checkout | items: []})
  end

  test "an unknown provider, a missing capability or missing keys stop before the provider" do
    assert {:error, %Errors.UnknownProvider{provider: "nope"}} =
             MishkaPay.checkout(%{@checkout | provider: "nope"})

    MishkaPay.Test.start_plugin!(CheckoutOnly)

    assert {:error, %Errors.Unsupported{provider: "checkout_only", operation: :refund}} =
             MishkaPay.refund(%{provider: "checkout_only", payment_id: "co_pi"})

    assert {:error, %Errors.MissingCredentials{provider: "checkout_only"}} =
             MishkaPay.checkout(%{@checkout | provider: "checkout_only"})

    for shipping <- [%{shipping_countries: ["NL"]}, %{shipping_rates: ["shr_1"]}] do
      assert {:error, %Errors.Unsupported{provider: "checkout_only", operation: :shipping}} =
               MishkaPay.checkout(Map.merge(%{@checkout | provider: "checkout_only"}, shipping))
    end
  end

  test "the host's gate can change a checkout or refuse it before the provider sees it" do
    MishkaPay.Test.start_plugin!(StockGate)

    assert {:ok, %Checkout{metadata: %{"channel" => "web"}}} = MishkaPay.checkout(@checkout)

    assert {:error, %Errors.Refused{operation: :checkout, reason: "the ebook is out of stock"}} =
             MishkaPay.checkout(%{@checkout | reference: "out-of-stock"})
  end

  @tag :capture_log
  test "a gate that answers junk, drops the checkout or exits refuses the sale" do
    MishkaPay.Test.start_plugin!(StockGate)

    for {reference, reason} <- [
          {"gate-junk", :invalid_answer},
          {"gate-no-checkout", :invalid_answer},
          {"gate-exit", :exited}
        ] do
      assert {:error, %Errors.Refused{reason: ^reason}} =
               MishkaPay.checkout(%{@checkout | reference: reference})
    end
  end

  # No time passes: a limit of 0 gives the hanging gate no time, and the refusal says why.
  test "a gate that never answers refuses at its time limit" do
    MishkaPay.Test.start_plugin!(StockGate)
    Application.put_env(:mishka_pay, :checkout_gate_timeout, 0)
    on_exit(fn -> Application.delete_env(:mishka_pay, :checkout_gate_timeout) end)

    assert {:error, %Errors.Refused{reason: :timeout}} =
             MishkaPay.checkout(%{@checkout | reference: "gate-hang"})
  end

  describe "customers and the portal" do
    test "a customer is deleted at the provider, and a provider without customers refuses before any call" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :customer_delete, :stop]])

      assert :ok = MishkaPay.delete_customer("acme", "acme_cus_1", "site-a")

      assert_received {[:mishka_pay, :customer_delete, :stop], ^ref, _,
                       %{provider: "acme", tenant: "site-a", outcome: :ok}}

      MishkaPay.Test.start_plugin!(CheckoutOnly)

      assert {:error, %Errors.Unsupported{provider: "checkout_only", operation: :customer}} =
               MishkaPay.delete_customer("checkout_only", "co_cus_1")
    end

    test "a customer is made, changed, read and listed, and its portal opened" do
      assert {:ok,
              %MishkaPay.Customer{id: "acme_cus_1", email: "ava@example.com", reference: "user-1"}} =
               MishkaPay.create_customer(%{
                 provider: "acme",
                 tenant: "site-a",
                 email: " Ava@Example.com ",
                 name: "Ava",
                 reference: "user-1"
               })

      assert {:ok, %{name: "Ava M."}} =
               MishkaPay.update_customer(%{
                 provider: "acme",
                 tenant: "site-a",
                 id: "acme_cus_1",
                 name: "Ava M."
               })

      assert {:ok, %MishkaPay.Customer{id: "acme_cus_1"}} =
               MishkaPay.fetch_customer("acme", "acme_cus_1", "site-a")

      assert {:ok, %MishkaPay.Page{items: [_one], has_more: true, next: next}} =
               MishkaPay.list_customers("acme", "site-a", limit: 1)

      assert {:ok, %MishkaPay.Page{items: [_two, _three], has_more: false, next: nil}} =
               MishkaPay.list_customers("acme", "site-a", limit: 5, after: next)

      assert {:ok, %MishkaPay.PortalSession{url: "https://pay.acme.test/portal/acme_cus_1"}} =
               MishkaPay.portal_session(%{
                 provider: "acme",
                 tenant: "site-a",
                 customer_id: "acme_cus_1",
                 return_url: "https://shop.test/account"
               })
    end

    test "portal configurations are made, read and listed, and a session names one" do
      assert {:ok, %MishkaPay.PortalConfiguration{id: "acme_bpc_1", subscription_cancel: :off}} =
               MishkaPay.create_portal_configuration(%{
                 provider: "acme",
                 tenant: "site-a",
                 name: "Teams",
                 subscription_cancel: "off"
               })

      assert {:ok, %MishkaPay.PortalConfiguration{name: "Monthly"}} =
               MishkaPay.update_portal_configuration(%{
                 provider: "acme",
                 tenant: "site-a",
                 id: "acme_bpc_1",
                 name: "Monthly"
               })

      assert {:ok, %MishkaPay.PortalConfiguration{default: true}} =
               MishkaPay.fetch_portal_configuration("acme", "acme_bpc_1", "site-a")

      assert {:ok, %MishkaPay.Page{items: [%MishkaPay.PortalConfiguration{}]}} =
               MishkaPay.list_portal_configurations("acme", "site-a", active: true)

      assert {:ok, %MishkaPay.PortalSession{configuration: "acme_bpc_1"}} =
               MishkaPay.portal_session(%{
                 provider: "acme",
                 tenant: "site-a",
                 customer_id: "acme_cus_1",
                 return_url: "https://shop.test/account",
                 configuration: "acme_bpc_1"
               })

      assert {:error, %Errors.Invalid{errors: [%{field: :id}]}} =
               MishkaPay.update_portal_configuration(%{provider: "acme", name: "No id"})

      MishkaPay.Test.start_plugin!(CheckoutOnly)

      assert {:error, %Errors.Unsupported{operation: :portal}} =
               MishkaPay.list_portal_configurations("checkout_only")
    end

    test "a call without its provider or id, and a portal with an unsafe return URL, are refused" do
      assert {:error, %Errors.Invalid{errors: [%{field: :provider}]}} =
               MishkaPay.create_customer(%{email: "ava@example.com"})

      assert {:error, %Errors.Invalid{errors: [%{field: :id}]}} =
               MishkaPay.update_customer(%{provider: "acme", name: "Ava"})

      assert {:error, %Errors.Invalid{errors: [%{field: :email}]}} =
               MishkaPay.create_customer(%{provider: "acme", email: "not an email"})

      assert {:error, %Errors.Invalid{errors: [%{field: :return_url}]}} =
               MishkaPay.portal_session(%{
                 provider: "acme",
                 customer_id: "acme_cus_1",
                 return_url: "http://evil.test/back"
               })
    end

    test "a checkout names its buyer by id or by email, not both" do
      assert {:error, %Errors.Invalid{errors: [%{field: :customer}]}} =
               MishkaPay.checkout(
                 Map.put(@checkout, :customer, %{id: "acme_cus_1", email: "ava@example.com"})
               )
    end
  end

  describe "coupons, promotion codes and checkout options" do
    test "a coupon and its promotion code are made, read, listed, turned off and the coupon removed" do
      assert {:ok, %MishkaPay.Coupon{id: "SPRING", percent_off: percent, duration: :once}} =
               MishkaPay.create_coupon(%{
                 provider: "acme",
                 tenant: "site-a",
                 id: "SPRING",
                 name: "Spring",
                 percent_off: "12.5"
               })

      assert Decimal.equal?(percent, Decimal.new("12.5"))

      assert {:ok, %MishkaPay.Coupon{id: "SPRING"}} =
               MishkaPay.fetch_coupon("acme", "SPRING", "site-a")

      assert {:ok, %MishkaPay.Page{items: [_one]}} =
               MishkaPay.list_coupons("acme", "site-a", limit: 1)

      assert {:ok, %MishkaPay.PromotionCode{id: "acme_promo_1", code: "SPRING10"}} =
               MishkaPay.create_promotion_code(%{
                 provider: "acme",
                 tenant: "site-a",
                 coupon_id: "SPRING",
                 code: "SPRING10",
                 minimum_amount: %{amount: "20", currency: "USD"}
               })

      assert {:ok, %MishkaPay.Page{items: [%{code: "ACME10"}]}} =
               MishkaPay.list_promotion_codes("acme", "site-a", code: "ACME10")

      assert {:ok, %MishkaPay.PromotionCode{active: false}} =
               MishkaPay.update_promotion_code(%{
                 provider: "acme",
                 tenant: "site-a",
                 id: "acme_promo_1",
                 active: false
               })

      assert {:ok, %MishkaPay.PromotionCode{coupon_id: "acme_coupon_1"}} =
               MishkaPay.fetch_promotion_code("acme", "acme_promo_1", "site-a")

      assert :ok = MishkaPay.delete_coupon("acme", "SPRING", "site-a")
    end

    test "a coupon takes a percent or an amount, and months only when it repeats" do
      for {attrs, field} <- [
            {%{percent_off: 10, amount_off: %{amount: "5", currency: "USD"}}, :percent_off},
            {%{}, :percent_off},
            {%{percent_off: 0}, :percent_off},
            {%{percent_off: "101"}, :percent_off},
            {%{percent_off: "ten"}, :percent_off},
            {%{percent_off: 10, duration: :repeating}, :duration_in_months},
            {%{percent_off: 10, duration: "once", duration_in_months: 3}, :duration_in_months}
          ] do
        assert {:error, %Errors.Invalid{errors: [%{field: ^field} | _]}} =
                 MishkaPay.create_coupon(Map.put(attrs, :provider, "acme"))
      end

      assert {:ok, %{duration: :repeating, duration_in_months: 3}} =
               MishkaPay.create_coupon(%{
                 provider: "acme",
                 amount_off: %{amount: "5", currency: "USD"},
                 duration: "repeating",
                 duration_in_months: 3
               })
    end

    test "a percent out of range is one error about the percent, not a missing discount" do
      assert {:error, %Errors.Invalid{errors: [%{field: :percent_off, message: message}]}} =
               MishkaPay.create_coupon(%{provider: "acme", percent_off: "150"})

      assert message =~ "at most 100"
    end

    test "a promotion code needs its coupon, and an update needs its id" do
      assert {:error, %Errors.Invalid{errors: [%{field: :coupon_id}]}} =
               MishkaPay.create_promotion_code(%{provider: "acme", code: "X"})

      assert {:error, %Errors.Invalid{errors: [%{field: :id}]}} =
               MishkaPay.update_promotion_code(%{provider: "acme", active: false})
    end

    test "a checkout applies a discount or lets the buyer type a code, never both" do
      assert {:ok, %Checkout{discounts: [%MishkaPay.Discount{promotion_code_id: "acme_promo_1"}]}} =
               MishkaPay.checkout(
                 Map.put(@checkout, :discounts, [%{promotion_code_id: "acme_promo_1"}])
               )

      assert {:error, %Errors.Invalid{errors: [%{field: :discounts}]}} =
               MishkaPay.checkout(
                 @checkout
                 |> Map.put(:discounts, [%{coupon_id: "SPRING"}])
                 |> Map.put(:allow_promotion_codes, true)
               )

      assert {:error, %Errors.Invalid{}} =
               MishkaPay.checkout(
                 Map.put(@checkout, :discounts, [%{coupon_id: "A", promotion_code_id: "promo_B"}])
               )
    end

    test "checkout options are checked: choices, a future expiry, customer creation only when paying once" do
      soon = DateTime.add(DateTime.utc_now(), 3600)

      assert {:ok,
              %Checkout{customer_creation: :always, billing_address: :required, locale: "de"}} =
               MishkaPay.checkout(
                 Map.merge(@checkout, %{
                   customer_creation: "always",
                   billing_address: "required",
                   locale: "de",
                   automatic_tax: true,
                   tax_id_collection: true,
                   expires_at: soon
                 })
               )

      assert {:error, %Errors.Invalid{errors: [%{field: :expires_at}]}} =
               MishkaPay.checkout(Map.put(@checkout, :expires_at, DateTime.add(soon, -7200)))

      assert {:error, %Errors.Invalid{errors: [%{field: :billing_address}]}} =
               MishkaPay.checkout(Map.put(@checkout, :billing_address, "sometimes"))

      plan = %{name: "Pro", amount: %{amount: "9", currency: "USD"}, interval: :month}

      assert {:error, %Errors.Invalid{errors: [%{field: :customer_creation}]}} =
               MishkaPay.checkout(
                 Map.merge(@checkout, %{
                   mode: :subscription,
                   items: [plan],
                   customer_creation: :always
                 })
               )
    end

    test "an open checkout is ended, and a provider without the capability refuses" do
      assert {:ok, %Checkout{status: :expired}} =
               MishkaPay.expire_checkout("acme", "acme_cs_order-1", "site-a")

      MishkaPay.Test.start_plugin!(CheckoutOnly)

      assert {:error, %Errors.Unsupported{operation: :expire}} =
               MishkaPay.expire_checkout("checkout_only", "co_cs_1")

      assert {:error, %Errors.Unsupported{operation: :discount}} =
               MishkaPay.create_coupon(%{provider: "checkout_only", percent_off: 10})
    end
  end

  describe "the catalog and lists page by page" do
    test "a product and its price are made, read, archived and listed" do
      assert {:ok, %MishkaPay.Product{id: "shop-ebook", active: true}} =
               MishkaPay.create_product(%{
                 provider: "acme",
                 tenant: "site-a",
                 id: "shop-ebook",
                 name: "Ebook",
                 tax_code: "txcd_10302000"
               })

      assert {:ok, %MishkaPay.Price{id: "acme_price_1", product_id: "shop-ebook"}} =
               MishkaPay.create_price(%{
                 provider: "acme",
                 tenant: "site-a",
                 product_id: "shop-ebook",
                 amount: %{amount: "19.99", currency: "USD"},
                 lookup_key: "ebook"
               })

      assert {:ok, %MishkaPay.Product{active: false}} =
               MishkaPay.archive_product("acme", "shop-ebook", "site-a")

      assert {:ok, %MishkaPay.Price{active: false}} =
               MishkaPay.archive_price("acme", "acme_price_1", "site-a")

      assert {:ok, %MishkaPay.Product{}} =
               MishkaPay.fetch_product("acme", "acme_prod_1", "site-a")

      assert {:ok, %MishkaPay.Price{}} = MishkaPay.fetch_price("acme", "acme_price_1", "site-a")
      assert {:ok, %MishkaPay.Page{items: [_price]}} = MishkaPay.list_prices("acme", "site-a")
    end

    test "a product needs its name, and a price its product and amount" do
      assert {:error, %Errors.Invalid{errors: [%{field: :name}]}} =
               MishkaPay.create_product(%{provider: "acme"})

      assert {:error, %Errors.Invalid{}} =
               MishkaPay.create_price(%{provider: "acme", product_id: "p"})

      assert {:error, %Errors.Invalid{errors: [%{field: :product_id}]}} =
               MishkaPay.create_price(%{
                 provider: "acme",
                 name: "x",
                 amount: %{amount: "1", currency: "USD"}
               })
    end

    test "a stream pages through every item, one request a page, only as far as it is read" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :product_list, :stop]])
      list = &MishkaPay.list_products("acme", "site-a", Keyword.put(&1, :limit, 1))

      assert [_one] = list |> MishkaPay.Page.stream() |> Enum.take(1)
      assert_received {[:mishka_pay, :product_list, :stop], ^ref, _, _}
      refute_received {[:mishka_pay, :product_list, :stop], ^ref, _, _}

      assert [_, _, _] = list |> MishkaPay.Page.stream() |> Enum.to_list()
    end

    test "a stream raises the error of a page it could not read" do
      assert_raise Errors.UnknownProvider, fn ->
        (&MishkaPay.list_products("nope", "site-a", &1))
        |> MishkaPay.Page.stream()
        |> Enum.to_list()
      end
    end

    test "payments are listed page by page, and a provider without the capability refuses" do
      assert {:ok, %MishkaPay.Page{items: [%Payment{}, %Payment{}], next: "2"}} =
               MishkaPay.list_payments("acme", "site-a", limit: 2)

      MishkaPay.Test.start_plugin!(CheckoutOnly)

      assert {:error, %Errors.Unsupported{operation: :payment_list}} =
               MishkaPay.list_payments("checkout_only")
    end
  end

  describe "payment links, invoices and tax behavior" do
    test "a link sells catalog prices with the limits the caller chose, and is turned off" do
      assert {:ok,
              %MishkaPay.PaymentLink{
                id: "acme_link_1",
                url: "https://pay.acme.test/l/1",
                max_purchases: 1,
                quantity_max: 5,
                customer_creation: :always
              } = link} =
               MishkaPay.create_payment_link(%{
                 provider: "acme",
                 tenant: "site-a",
                 items: [%{id: "price_1", quantity: 1}],
                 success_url: "https://shop.test/thanks",
                 max_purchases: 1,
                 inactive_message: "Sold out",
                 quantity_min: 1,
                 quantity_max: 5,
                 customer_creation: "always",
                 invoice: true
               })

      assert MishkaPay.PaymentLink.url(link, reference: "order-42", email: "ava@example.com") ==
               "https://pay.acme.test/l/1?client_reference_id=order-42&prefilled_email=ava%40example.com"

      assert MishkaPay.PaymentLink.url(link) == "https://pay.acme.test/l/1"

      assert_raise ArgumentError, ~r/reference/, fn ->
        MishkaPay.PaymentLink.url(link, reference: "order 42")
      end

      assert {:ok, %MishkaPay.PaymentLink{active: false}} =
               MishkaPay.update_payment_link(%{
                 provider: "acme",
                 id: "acme_link_1",
                 active: false
               })

      assert {:ok, %MishkaPay.PaymentLink{purchases: 0}} =
               MishkaPay.fetch_payment_link("acme", "acme_link_1", "site-a")

      assert {:ok, %MishkaPay.Page{items: [_, _]}} =
               MishkaPay.list_payment_links("acme", "site-a")
    end

    test "a link needs catalog prices by id, and an update its id" do
      for items <- [nil, [], [%{name: "Ebook", amount: %{amount: "1", currency: "USD"}}]] do
        assert {:error, %Errors.Invalid{errors: [%{field: :items} | _]}} =
                 MishkaPay.create_payment_link(%{provider: "acme", items: items})
      end

      assert {:error, %Errors.Invalid{errors: [%{field: :id}]}} =
               MishkaPay.update_payment_link(%{provider: "acme", active: false})

      for {min, max} <- [{5, 2}, {2, 2}] do
        assert {:error, %Errors.Invalid{errors: [%{field: :quantity_min}]}} =
                 MishkaPay.create_payment_link(%{
                   provider: "acme",
                   items: [%{id: "price_1"}],
                   quantity_min: min,
                   quantity_max: max
                 })
      end

      assert {:error, %Errors.Invalid{errors: [%{field: :quantity_max}]}} =
               MishkaPay.create_payment_link(%{
                 provider: "acme",
                 items: [%{id: "price_1"}],
                 quantity_max: 1_000_000
               })

      assert {:error, %Errors.Invalid{errors: [%{field: :success_url}]}} =
               MishkaPay.create_payment_link(%{
                 provider: "acme",
                 items: [%{id: "price_1"}],
                 success_url: "http://evil.test/"
               })
    end

    test "an invoice is a one-time checkout's choice, and a price says how its tax counts" do
      assert {:ok, %Checkout{invoice: true}} =
               MishkaPay.checkout(Map.put(@checkout, :invoice, true))

      plan = %{name: "Pro", amount: %{amount: "9", currency: "USD"}, interval: :month}

      assert {:error, %Errors.Invalid{errors: [%{field: :invoice}]}} =
               MishkaPay.checkout(
                 Map.merge(@checkout, %{mode: :subscription, items: [plan], invoice: true})
               )

      assert {:ok, %Checkout{items: [%MishkaPay.Price{tax_behavior: :inclusive}]}} =
               MishkaPay.checkout(
                 Map.put(@checkout, :items, [
                   %{
                     name: "Ebook",
                     amount: %{amount: "20", currency: "EUR"},
                     tax_behavior: "inclusive"
                   }
                 ])
               )

      assert {:error, %Errors.Invalid{}} =
               MishkaPay.checkout(
                 Map.put(@checkout, :items, [
                   %{
                     name: "Ebook",
                     amount: %{amount: "20", currency: "EUR"},
                     tax_behavior: "maybe"
                   }
                 ])
               )
    end
  end

  describe "subscriptions" do
    test "are read, cancelled at the period's end or now, taken back, and their invoices listed" do
      assert {:ok, %MishkaPay.Subscription{id: "acme_sub_active", status: :active, items: [plan]}} =
               MishkaPay.fetch_subscription("acme", "acme_sub_active", "site-a")

      assert {plan.interval, plan.amount} == {:month, Money.new(:USD, "9.00")}

      assert {:ok, %{status: :active, cancel_at_period_end: true}} =
               MishkaPay.cancel_subscription("acme", "acme_sub_active", "site-a")

      assert {:ok, %{status: :canceled}} =
               MishkaPay.cancel_subscription("acme", "acme_sub_active", "site-a", at: :now)

      assert {:ok, %{cancel_at_period_end: false}} =
               MishkaPay.resume_subscription("acme", "acme_sub_active", "site-a")

      assert {:ok,
              %MishkaPay.Page{
                items: [%MishkaPay.Invoice{status: :paid, subscription_id: "acme_sub_active"}]
              }} =
               MishkaPay.list_invoices("acme", "site-a", subscription_id: "acme_sub_active")

      assert_raise ArgumentError, ~r/must be :now or :period_end/, fn ->
        MishkaPay.cancel_subscription("acme", "acme_sub_active", "site-a", at: :tomorrow)
      end
    end

    test "a plan or a quantity changes with the proration the caller chose, previewed first" do
      change = %{
        provider: "acme",
        tenant: "site-a",
        subscription_id: "acme_sub_active",
        price_id: "acme_price_team",
        quantity: 3,
        proration: "always_invoice"
      }

      assert {:ok, %MishkaPay.Invoice{amount_due: due, lines: [credit, charge]} = preview} =
               MishkaPay.preview_subscription_change(change)

      assert Money.equal?(due, Money.new(:USD, "4.50"))
      assert credit.proration and charge.proration
      assert "acme_upcoming_" <> _ = preview.id

      assert {:ok, %MishkaPay.Subscription{items: [%{id: "acme_price_team", quantity: 3}]}} =
               MishkaPay.change_subscription(change)

      assert {:error, %Errors.Invalid{errors: [%{field: :price_id}]}} =
               MishkaPay.change_subscription(%{
                 provider: "acme",
                 subscription_id: "acme_sub_active"
               })

      assert {:error, %Errors.Invalid{errors: [%{field: :proration}]}} =
               MishkaPay.change_subscription(Map.put(change, :proration, "sometimes"))

      for with_date <- [%{proration: :none}, %{billing_cycle_anchor: :now}] do
        attrs = change |> Map.merge(with_date) |> Map.put(:proration_date, DateTime.utc_now())

        assert {:error, %Errors.Invalid{errors: [%{field: :proration_date}]}} =
                 MishkaPay.change_subscription(attrs)

        assert {:ok, %MishkaPay.Invoice{}} =
                 MishkaPay.preview_subscription_change(Map.merge(change, with_date))
      end
    end

    test "collection pauses with the behavior the caller chose, resumes, and an invoice is read" do
      later = DateTime.add(DateTime.utc_now(), 30, :day)

      assert {:ok, %MishkaPay.Subscription{pause_behavior: :keep_as_draft, resumes_at: ^later}} =
               MishkaPay.pause_collection("acme", "acme_sub_active", "site-a",
                 behavior: :keep_as_draft,
                 resumes_at: later
               )

      assert {:ok, %MishkaPay.Subscription{pause_behavior: :void}} =
               MishkaPay.pause_collection("acme", "acme_sub_active", "site-a")

      assert {:error, %Errors.Invalid{errors: [%{field: :behavior}]}} =
               MishkaPay.pause_collection("acme", "acme_sub_active", "site-a", behavior: :forever)

      assert {:ok, %MishkaPay.Subscription{pause_behavior: nil}} =
               MishkaPay.resume_collection("acme", "acme_sub_active", "site-a")

      assert {:ok, %MishkaPay.Invoice{lines: [%MishkaPay.InvoiceLine{description: "Pro plan"}]}} =
               MishkaPay.fetch_invoice("acme", "acme_in_1", "site-a")
    end

    test "a provider without subscriptions refuses a subscription checkout and every call" do
      MishkaPay.Test.start_plugin!(CheckoutOnly)

      monthly = %{name: "Pro", amount: %{amount: "9", currency: "USD"}, interval: :month}

      assert {:error, %Errors.Unsupported{operation: :subscription}} =
               MishkaPay.checkout(
                 %{
                   @checkout
                   | provider: "checkout_only",
                     items: [monthly]
                 }
                 |> Map.put(:mode, :subscription)
               )

      assert {:error, %Errors.Unsupported{operation: :subscription}} =
               MishkaPay.fetch_subscription("checkout_only", "sub_1")
    end

    test "a provider that bills without keeping charges between bills refuses invoice items" do
      assert {:error, %Errors.Unsupported{provider: "acme", operation: :invoice_item}} =
               MishkaPay.list_invoice_items("acme", "site-a", customer_id: "acme_cus_1")

      assert {:error, %Errors.Invalid{errors: [%{field: :amount}]}} =
               MishkaPay.create_invoice_item(%{provider: "acme", customer_id: "acme_cus_1"})
    end

    test "a provider with subscriptions but no list of them refuses a list and a search" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:mishka_pay, :subscription_list, :stop],
          [:mishka_pay, :subscription_search, :stop]
        ])

      assert {:error, %Errors.Unsupported{provider: "acme", operation: :subscription_list}} =
               MishkaPay.list_subscriptions("acme", "site-a", customer_id: "acme_cus_1")

      assert {:error, %Errors.Unsupported{operation: :subscription_list}} =
               MishkaPay.search_subscriptions("acme", "site-a", status: :active)

      for operation <- [:subscription_list, :subscription_search] do
        assert_received {[:mishka_pay, ^operation, :stop], ^ref, _,
                         %{provider: "acme", tenant: "site-a", outcome: :provider}}
      end
    end
  end

  test "an embedded form or a hold on the card needs its capability, asked before the provider" do
    embedded =
      @checkout
      |> Map.drop([:success_url, :cancel_url])
      |> Map.merge(%{ui_mode: :embedded, return_url: "https://shop.test/return"})

    assert {:error, %Errors.Unsupported{provider: "acme", operation: :embedded_checkout}} =
             MishkaPay.checkout(embedded)

    assert {:error, %Errors.Unsupported{operation: :capture}} =
             MishkaPay.checkout(Map.put(@checkout, :capture, :manual))

    assert {:error, %Errors.Unsupported{operation: :capture}} =
             MishkaPay.capture_payment("acme", "acme_paid", "site-a")

    assert {:error, %Errors.Unsupported{operation: :capture}} =
             MishkaPay.cancel_payment("acme", "acme_paid", "site-a")

    assert {:ok, %Checkout{ui_mode: :hosted}} =
             MishkaPay.checkout(Map.put(@checkout, :capture, "automatic"))
  end

  test "a checkout's pages fit its ui mode: two for a hosted page, one for an embedded form" do
    embedded = Map.merge(@checkout, %{ui_mode: "embedded", return_url: "https://shop.test/r"})

    for {attrs, field} <- [
          {Map.delete(@checkout, :cancel_url), :cancel_url},
          {Map.put(@checkout, :return_url, "https://shop.test/r"), :return_url},
          {embedded, :success_url},
          {Map.drop(embedded, [:success_url, :cancel_url, :return_url]), :return_url},
          {Map.merge(@checkout, %{capture: :manual, mode: :subscription}), :capture}
        ] do
      assert {:error, %Errors.Invalid{errors: [%{field: ^field}]}} = MishkaPay.checkout(attrs)
    end
  end

  test "a checkout is read again by its id, with the payment it made" do
    assert {:ok, %Checkout{id: "acme_cs_o-9", status: :complete, payment_id: "acme_paid"}} =
             MishkaPay.fetch_checkout("acme", "acme_cs_o-9", "site-a")
  end

  test "a payment is read again from the provider, and a refund is made there" do
    assert {:ok, %Payment{id: "acme_paid", status: :paid}} =
             MishkaPay.fetch_payment("acme", "acme_paid", "site-a")

    assert {:ok, %Refund{id: "acme_re_1", status: :succeeded, payment_id: "acme_paid"}} =
             MishkaPay.refund(%{provider: "acme", tenant: "site-a", payment_id: "acme_paid"})
  end
end

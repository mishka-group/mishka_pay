defmodule ShopWeb.CheckoutOptionsComponentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  @session %{
    "object" => "checkout.session",
    "id" => "cs_test_more",
    "url" => "https://checkout.stripe.com/c/pay/cs_test_more",
    "status" => "open"
  }

  setup do
    seed_product("hoodie", "Elixir hoodie", "39.00", nil)
    seed_product("team-monthly", "Team plan", "29.00", :month)
    :ok
  end

  test "every option of a one-time checkout goes to Stripe, then the buyer goes there",
       %{conn: conn} do
    StripeRoutes.stub(%{{"POST", "/v1/checkout/sessions"} => @session})
    {:ok, view, _html} = live(conn, ~p"/")

    assert {:error, {:redirect, %{to: "https://checkout.stripe.com/c/pay/cs_test_more"}}} =
             view
             |> form("[data-testid=checkout-more-form]", %{
               "product" => "hoodie",
               "merchant_of_record" => "off",
               "phone" => "true",
               "terms" => "true",
               "pay_later" => "true",
               "submit_type" => "book",
               "description" => "One hoodie, size M",
               "statement_suffix" => "ORDER 42",
               "q1_label" => "Name on the card",
               "q2_label" => "Size",
               "q2_type" => "dropdown",
               "q2_options" => "Small, Medium",
               "q2_optional" => "true",
               "q3_label" => "Lucky number",
               "q3_type" => "numeric",
               "shipping_countries" => "nl, DE",
               "ship_name" => "Standard post",
               "ship_amount" => "4.95",
               "ship_min" => "2",
               "ship_max" => "5"
             })
             |> render_submit()

    assert_received {:stripe, "POST", "/v1/checkout/sessions", params}
    assert params["mode"] == "payment"
    assert params["phone_number_collection"] == %{"enabled" => "true"}
    assert params["consent_collection"] == %{"terms_of_service" => "required"}
    assert params["submit_type"] == "book"
    assert params["payment_intent_data"]["capture_method"] == "manual"
    assert params["payment_intent_data"]["description"] == "One hoodie, size M"
    assert params["payment_intent_data"]["statement_descriptor_suffix"] == "ORDER 42"

    assert params["shipping_address_collection"]["allowed_countries"] == %{
             "0" => "NL",
             "1" => "DE"
           }

    [rate] = Map.values(params["shipping_options"])
    assert rate["shipping_rate_data"]["display_name"] == "Standard post"
    assert rate["shipping_rate_data"]["fixed_amount"]["amount"] == "495"

    fields = params["custom_fields"] |> Map.values() |> Map.new(&{&1["key"], &1})
    assert fields["nameonthecard"]["type"] == "text"
    assert fields["size"]["type"] == "dropdown"
    assert fields["size"]["optional"] == "true"

    assert Enum.map(Map.values(fields["size"]["dropdown"]["options"]), & &1["value"]) --
             ["small", "medium"] == []

    assert fields["luckynumber"]["type"] == "numeric"
  end

  test "a plan's trial can start without a card", %{conn: conn} do
    StripeRoutes.stub(%{{"POST", "/v1/checkout/sessions"} => @session})
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=checkout-more-form]", %{
      "product" => "team-monthly",
      "trial_days" => "7",
      "no_card" => "true"
    })
    |> render_submit()

    assert_received {:stripe, "POST", "/v1/checkout/sessions", params}
    assert params["mode"] == "subscription"
    assert params["subscription_data"]["trial_period_days"] == "7"
    assert params["payment_method_collection"] == "if_required"
  end

  test "a card statement suffix with merchant of record on is refused in plain words",
       %{conn: conn} do
    StripeRoutes.stub(%{{"POST", "/v1/checkout/sessions"} => @session})
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=checkout-more-form]", %{
      "product" => "hoodie",
      "merchant_of_record" => "on",
      "statement_suffix" => "ORDER 42"
    })
    |> render_submit()

    refute_received {:stripe, "POST", "/v1/checkout/sessions", _params}
    assert render(view) =~ "statement_suffix"
  end

  test "an embedded checkout mounts Stripe's form with its secret and the publishable key",
       %{conn: conn} do
    StripeRoutes.stub(%{
      {"POST", "/v1/checkout/sessions"} =>
        Map.merge(@session, %{
          "url" => nil,
          "ui_mode" => "embedded_page",
          "client_secret" => "cs_test_more_secret_1"
        })
    })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=checkout-more-form]", %{"product" => "hoodie", "ui_mode" => "embedded"})
    |> render_submit()

    assert_received {:stripe, "POST", "/v1/checkout/sessions", params}
    assert params["ui_mode"] == "embedded_page"
    assert params["return_url"] =~ "session_id={CHECKOUT_SESSION_ID}"
    refute Map.has_key?(params, "success_url")

    assert has_element?(
             view,
             ~s|[data-testid=embedded-checkout][phx-hook][data-client-secret="cs_test_more_secret_1"][data-publishable-key="pk_test_shop"]|
           )

    view |> element("[data-testid=embedded-close]") |> render_click()
    refute has_element?(view, "[data-testid=embedded-checkout]")
  end

  test "what was picked stays picked through later changes and the checkout opening, and is sent again",
       %{conn: conn} do
    StripeRoutes.stub(%{
      {"POST", "/v1/checkout/sessions"} =>
        Map.merge(@session, %{
          "url" => nil,
          "ui_mode" => "embedded_page",
          "client_secret" => "cs_test_more_secret_1"
        })
    })

    {:ok, view, _html} = live(conn, ~p"/")
    form = "[data-testid=checkout-more-form]"

    for change <- [
          %{"product" => "hoodie"},
          %{"ui_mode" => "embedded"},
          %{"submit_type" => "donate"},
          %{"q1_type" => "dropdown"},
          %{"q1_label" => "Size", "q1_options" => "S, M"},
          %{"phone" => "true"}
        ],
        do: view |> form(form, change) |> render_change()

    assert has_element?(view, "[data-testid=more-submit-type] option[value=donate][selected]")

    for _time <- 1..2 do
      view |> form(form) |> render_submit()
      assert has_element?(view, "[data-testid=embedded-checkout]")

      assert_received {:stripe, "POST", "/v1/checkout/sessions", params}
      assert params["ui_mode"] == "embedded_page"
      assert params["submit_type"] == "donate"
      assert params["phone_number_collection"] == %{"enabled" => "true"}

      assert %{"0" => %{"type" => "dropdown", "label" => %{"custom" => "Size"}}} =
               params["custom_fields"]
    end
  end

  test "an embedded checkout without a publishable key says how to add one", %{conn: conn} do
    StripeRoutes.stub(%{{"POST", "/v1/checkout/sessions"} => @session}, %{publishable_key: nil})
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=checkout-more-form]", %{"product" => "hoodie", "ui_mode" => "embedded"})
    |> render_submit()

    refute_received {:stripe, "POST", "/v1/checkout/sessions", _params}
    assert render(view) =~ "STRIPE_PUBLISHABLE_KEY"
    refute has_element?(view, "[data-testid=embedded-checkout]")
  end

  test "read back, a checkout shows the phone, answers, terms, address and items sold",
       %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/checkout/sessions/cs_test_done"} => %{
        "object" => "checkout.session",
        "id" => "cs_test_done",
        "status" => "complete",
        "currency" => "usd",
        "amount_total" => 4395,
        "payment_intent" => "pi_done",
        "customer_details" => %{"phone" => "+31201234567", "email" => "ada@example.com"},
        "custom_fields" => [
          %{"key" => "size", "dropdown" => %{"value" => "medium"}},
          %{"key" => "nameonthecard", "text" => %{"value" => "Ada"}}
        ],
        "consent" => %{"terms_of_service" => "accepted"},
        "collected_information" => %{
          "shipping_details" => %{
            "name" => "Ada Lovelace",
            "address" => %{"line1" => "Dam 1", "city" => "Amsterdam", "country" => "NL"}
          }
        },
        "total_details" => %{"amount_shipping" => 495},
        "line_items" =>
          StripeRoutes.list([
            %{
              "description" => "Elixir hoodie",
              "quantity" => 1,
              "price" => %{
                "id" => "price_hoodie",
                "product" => "prod_hoodie",
                "unit_amount" => 3900,
                "currency" => "usd"
              }
            }
          ])
      }
    })

    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("[data-testid=readback-form]", checkout_id: "cs_test_done") |> render_submit()

    assert view |> element("[data-testid=readback-phone]") |> render() =~ "+31201234567"
    assert view |> element("[data-testid=readback-field][data-key=size]") |> render() =~ "medium"
    assert view |> element("[data-testid=readback-terms]") |> render() =~ "yes"
    assert view |> element("[data-testid=readback-shipping]") |> render() =~ "Amsterdam"
    assert view |> element("[data-testid=readback-shipping-amount]") |> render() =~ "$4.95"

    assert view
           |> element("[data-testid=readback-item][data-price-id=price_hoodie]")
           |> render() =~ "Elixir hoodie"
  end

  test "reading back a payment id is refused in plain words", %{conn: conn} do
    StripeRoutes.stub(%{})
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("[data-testid=readback-form]", checkout_id: "pi_nope") |> render_submit()

    assert render(view) =~ "That is a payment id"
    refute has_element?(view, "[data-testid=readback-card]")
  end

  defp seed_product(slug, name, price, interval) do
    Ash.create!(
      Shop.Catalog.Product,
      %{slug: slug, name: name, price: price, interval: interval, position: 1},
      action: :seed,
      authorize?: false
    )
  end
end

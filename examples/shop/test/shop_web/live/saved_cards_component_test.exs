defmodule ShopWeb.SavedCardsComponentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  @visa %{
    "object" => "payment_method",
    "id" => "pm_visa",
    "type" => "card",
    "customer" => "cus_ada",
    "card" => %{"brand" => "visa", "last4" => "4242", "exp_month" => 12, "exp_year" => 2030}
  }

  @mastercard %{
    "object" => "payment_method",
    "id" => "pm_mc",
    "type" => "card",
    "customer" => "cus_ada",
    "card" => %{"brand" => "mastercard", "last4" => "4444", "exp_month" => 1, "exp_year" => 2031}
  }

  test "Save a card opens a setup checkout for the customer, charging nothing", %{conn: conn} do
    StripeRoutes.stub(%{
      {"POST", "/v1/checkout/sessions"} => %{
        "object" => "checkout.session",
        "id" => "cs_test_setup",
        "url" => "https://checkout.stripe.com/c/pay/cs_test_setup",
        "status" => "open"
      }
    })

    {:ok, view, _html} = live(conn, ~p"/")

    assert {:error, {:redirect, %{to: "https://checkout.stripe.com/c/pay/cs_test_setup"}}} =
             view
             |> form("[data-testid=cards-form]", customer_id: "cus_ada")
             |> render_submit(%{"do" => "save"})

    assert_received {:stripe, "POST", "/v1/checkout/sessions", params}
    assert params["mode"] == "setup"
    assert params["currency"] == "usd"
    assert params["customer"] == "cus_ada"
    refute Map.has_key?(params, "line_items")
  end

  test "back from a setup checkout, the page says the card is saved", %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/checkout/sessions/cs_test_setup"} => %{
        "object" => "checkout.session",
        "id" => "cs_test_setup",
        "status" => "complete",
        "customer" => "cus_ada",
        "setup_intent" => %{"id" => "seti_1", "payment_method" => "pm_visa"}
      }
    })

    {:ok, view, _html} = live(conn, ~p"/?session_id=cs_test_setup")

    assert render_async(view) =~ "Card saved"
  end

  test "no customer given is refused in plain words before Stripe is asked", %{conn: conn} do
    StripeRoutes.stub(%{})
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("[data-testid=cards-form]") |> render_submit(%{"do" => "list"})

    refute_received {:stripe, "GET", "/v1/customers/" <> _, _params}
    assert render(view) =~ "Pick a customer"
  end

  test "the cards are listed with the default marked; another is made default, one detached",
       %{conn: conn} do
    stub_cards([@visa, @mastercard], "pm_visa")
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("[data-testid=cards-form]", customer_id: "cus_ada") |> render_submit()

    assert has_element?(
             view,
             "[data-testid=card-row][data-payment-method-id=pm_visa] [data-testid=card-default]"
           )

    assert view |> element("[data-payment-method-id=pm_mc]") |> render() =~ "mastercard •••• 4444"

    view
    |> element("[data-payment-method-id=pm_mc] [data-testid=card-make-default]")
    |> render_click()

    assert_received {:stripe, "POST", "/v1/customers/cus_ada",
                     %{"invoice_settings" => %{"default_payment_method" => "pm_mc"}}}

    assert has_element?(view, "[data-payment-method-id=pm_mc] [data-testid=card-default]")
    refute has_element?(view, "[data-payment-method-id=pm_visa] [data-testid=card-default]")

    stub_cards([@mastercard], "pm_mc")

    view
    |> element("[data-payment-method-id=pm_visa] [data-testid=card-detach]")
    |> render_click()

    assert_received {:stripe, "POST", "/v1/payment_methods/pm_visa/detach", _params}
    refute has_element?(view, "[data-payment-method-id=pm_visa]")
    assert has_element?(view, "[data-payment-method-id=pm_mc]")
  end

  test "a customer with no cards says so", %{conn: conn} do
    stub_cards([], nil)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("[data-testid=cards-form]", customer_id: "cus_ada") |> render_submit()

    assert has_element?(view, "[data-testid=cards-empty]")
  end

  test "a portal link opens on one task, with the subscription it is about", %{conn: conn} do
    StripeRoutes.stub(%{
      {"POST", "/v1/billing_portal/sessions"} => %{
        "object" => "billing_portal.session",
        "id" => "bps_1",
        "url" => "https://billing.stripe.com/p/session/bps_1"
      }
    })

    {:ok, view, _html} = live(conn, ~p"/")

    assert {:error, {:redirect, %{to: "https://billing.stripe.com/p/session/bps_1"}}} =
             view
             |> form("[data-testid=portal-flow-form]", %{
               "customer_id" => "cus_ada",
               "flow" => "payment_method_update"
             })
             |> render_submit()

    assert_received {:stripe, "POST", "/v1/billing_portal/sessions", params}
    assert params["customer"] == "cus_ada"
    assert params["flow_data"]["type"] == "payment_method_update"
    assert params["flow_data"]["after_completion"]["redirect"]["return_url"] =~ "portal=back"
  end

  test "cancelling a subscription in the portal needs the subscription", %{conn: conn} do
    StripeRoutes.stub(%{})
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=portal-flow-form]", %{
      "customer_id" => "cus_ada",
      "flow" => "subscription_cancel"
    })
    |> render_submit()

    refute_received {:stripe, "POST", "/v1/billing_portal/sessions", _params}
    assert render(view) =~ "subscription"
  end

  defp stub_cards(cards, default) do
    StripeRoutes.stub(%{
      {"GET", "/v1/customers/cus_ada/payment_methods"} => StripeRoutes.list(cards),
      {"GET", "/v1/customers/cus_ada"} => customer(default),
      {"POST", "/v1/customers/cus_ada"} => fn params ->
        customer(params["invoice_settings"]["default_payment_method"])
      end,
      {"POST", "/v1/payment_methods/pm_visa/detach"} => Map.put(@visa, "customer", nil)
    })
  end

  defp customer(default) do
    %{
      "object" => "customer",
      "id" => "cus_ada",
      "email" => "ada@example.com",
      "invoice_settings" => %{"default_payment_method" => default}
    }
  end
end

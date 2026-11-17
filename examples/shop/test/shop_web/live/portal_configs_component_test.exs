defmodule ShopWeb.PortalConfigsComponentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  test "setups are read only when shown, page by page; one is made, turned off, and the portal opens with one",
       %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/billing_portal/configurations"} => fn
        %{"starting_after" => "bpc_default"} -> page([config("bpc_old", "Old", false)], false)
        _first -> page([config("bpc_default", "Default", true)], true)
      end,
      {"POST", "/v1/billing_portal/configurations"} => config("bpc_teams", "Teams", false),
      {"POST", "/v1/billing_portal/configurations/bpc_teams"} =>
        Map.put(config("bpc_teams", "Teams", false), "active", false),
      {"POST", "/v1/billing_portal/sessions"} => %{
        "object" => "billing_portal.session",
        "id" => "bps_1",
        "url" => "https://billing.stripe.com/p/session/test_1"
      }
    })

    {:ok, view, _html} = live(conn, ~p"/")

    refute_received {:stripe, "GET", "/v1/billing_portal/configurations", _params}
    refute has_element?(view, "[data-testid=portal-config-list]")

    view |> element("[data-testid=portal-configs-show]") |> render_click()
    render_async(view)

    assert_received {:stripe, "GET", "/v1/billing_portal/configurations", listed}
    assert listed["expand"] == ["data.features.subscription_update.products"]

    assert has_element?(
             view,
             "[data-testid=portal-config-row][data-config-id=bpc_default][data-default=true]"
           )

    refute has_element?(
             view,
             "[data-testid=portal-config-row][data-config-id=bpc_default] [data-testid=portal-config-toggle]"
           )

    view |> element("[data-testid=portal-config-next]") |> render_click()
    render_async(view)
    assert has_element?(view, "[data-testid=portal-config-row][data-config-id=bpc_old]")
    view |> element("[data-testid=portal-config-first]") |> render_click()
    render_async(view)

    view
    |> form("[data-testid=portal-config-form]", %{
      "name" => "Teams",
      "headline" => "Teams billing",
      "subscription_cancel" => "at_period_end",
      "invoice_history" => "true",
      "customer_update" => ["email", "tax_id"],
      "product_id" => "prod_team",
      "price_ids" => "price_month, price_year"
    })
    |> render_submit()

    assert_received {:stripe, "POST", "/v1/billing_portal/configurations", made}
    assert made["name"] == "Teams"

    assert %{
             "subscription_cancel" => %{"enabled" => "true", "mode" => "at_period_end"},
             "invoice_history" => %{"enabled" => "true"},
             "payment_method_update" => %{"enabled" => "false"},
             "customer_update" => %{"enabled" => "true"},
             "subscription_update" => %{
               "enabled" => "true",
               "products" => %{"0" => %{"product" => "prod_team", "prices" => prices}}
             }
           } = made["features"]

    assert prices == %{"0" => "price_month", "1" => "price_year"}
    assert has_element?(view, "[data-testid=portal-config-row][data-config-id=bpc_teams]")

    view
    |> element(
      "[data-testid=portal-config-row][data-config-id=bpc_teams] [data-testid=portal-config-toggle]"
    )
    |> render_click()

    assert_received {:stripe, "POST", "/v1/billing_portal/configurations/bpc_teams",
                     %{"active" => "false"}}

    assert has_element?(
             view,
             "[data-testid=portal-config-row][data-config-id=bpc_teams][data-active=false]"
           )

    view
    |> form("[data-testid=portal-open-form]", %{
      "customer_id" => "cus_ada",
      "configuration" => "bpc_default"
    })
    |> render_submit()

    assert_received {:stripe, "POST", "/v1/billing_portal/sessions", session}
    assert %{"customer" => "cus_ada", "configuration" => "bpc_default"} = session
    assert_redirect(view, "https://billing.stripe.com/p/session/test_1")
  end

  test "a portal without a customer, a setup without a name, or one Stripe refuses, says why", %{
    conn: conn
  } do
    StripeRoutes.stub(%{
      {"POST", "/v1/billing_portal/configurations"} =>
        StripeRoutes.error(400, "Invalid URL: not a url", "business_profile[privacy_policy_url]")
    })

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=portal-configs-show]") |> render_click()
    render_async(view)
    assert has_element?(view, "[data-testid=portal-config-empty]")

    view |> form("[data-testid=portal-open-form]", %{}) |> render_submit()
    refute_received {:stripe, "POST", "/v1/billing_portal/sessions", _params}
    assert view |> element("#flash-error") |> render() =~ "Pick a customer"

    view |> form("[data-testid=portal-config-form]", %{"name" => "  "}) |> render_submit()
    refute_received {:stripe, "POST", "/v1/billing_portal/configurations", _params}
    assert view |> element("#flash-error") |> render() =~ "Give the setup a name"

    view |> form("[data-testid=portal-config-form]", %{"name" => "Broken"}) |> render_submit()
    assert_received {:stripe, "POST", "/v1/billing_portal/configurations", _params}
    assert view |> element("#flash-error") |> render() =~ "Stripe"
    refute has_element?(view, "[data-testid=portal-config-row]")
  end

  defp page(items, more?), do: %{StripeRoutes.list(items) | "has_more" => more?}

  defp config(id, name, default?) do
    %{
      "object" => "billing_portal.configuration",
      "id" => id,
      "name" => name,
      "active" => true,
      "is_default" => default?,
      "created" => 1_794_000_000,
      "business_profile" => %{},
      "metadata" => %{},
      "features" => %{
        "invoice_history" => %{"enabled" => true},
        "payment_method_update" => %{"enabled" => false},
        "customer_update" => %{"enabled" => false, "allowed_updates" => []},
        "subscription_cancel" => %{"enabled" => true, "mode" => "at_period_end"},
        "subscription_update" => %{"enabled" => false, "default_allowed_updates" => []}
      }
    }
  end
end

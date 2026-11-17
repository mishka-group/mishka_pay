defmodule ShopWeb.SubscriptionFinderComponentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  test "a customer's subscriptions are listed by status, page by page, and one is kept in the shop",
       %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/subscriptions"} => fn
        %{"starting_after" => "sub_one"} -> page([subscription("sub_two", "canceled")], false)
        _first -> page([subscription("sub_one", "active")], true)
      end,
      {"GET", "/v1/subscriptions/sub_one"} => subscription("sub_one", "active")
    })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=sub-finder-form]", %{
      "mode" => "list",
      "status" => "all",
      "customer_id" => "cus_ada",
      "limit" => "1"
    })
    |> render_submit()

    assert_received {:stripe, "GET", "/v1/subscriptions", query}
    assert %{"customer" => "cus_ada", "status" => "all", "limit" => "1"} = query

    assert has_element?(
             view,
             "[data-testid=sub-finder-row][data-subscription-id=sub_one][data-status=active]"
           )

    assert view |> element("[data-testid=sub-finder-page]") |> render() =~ "Page 1"

    view |> element("[data-testid=sub-finder-next]") |> render_click()

    assert_received {:stripe, "GET", "/v1/subscriptions", %{"starting_after" => "sub_one"}}
    assert has_element?(view, "[data-testid=sub-finder-row][data-subscription-id=sub_two]")
    assert has_element?(view, "[data-testid=sub-finder-last]")
    refute has_element?(view, "[data-testid=sub-finder-next]")

    view
    |> form("[data-testid=sub-finder-form]", %{"mode" => "list", "status" => "", "limit" => "1"})
    |> render_submit()

    view |> element("[data-testid=sub-finder-open]") |> render_click()

    assert_received {:stripe, "GET", "/v1/subscriptions/sub_one", _params}
    assert has_element?(view, "[data-testid=subscription-row][data-subscription-id=sub_one]")
  end

  test "a search sends Stripe's query, and a refused id says why", %{conn: conn} do
    StripeRoutes.stub(%{{"GET", "/v1/subscriptions/search"} => page([], false)})
    {:ok, view, _html} = live(conn, ~p"/")
    view |> form("[data-testid=sub-finder-form]", %{"mode" => "search"}) |> render_change()

    view
    |> form("[data-testid=sub-finder-form]", %{
      "mode" => "search",
      "status" => "past_due",
      "reference" => "order-1",
      "metadata" => "plan=pro"
    })
    |> render_submit()

    assert_received {:stripe, "GET", "/v1/subscriptions/search", %{"query" => query}}

    assert query ==
             "status:'past_due' AND metadata['mishka_pay_reference']:'order-1' AND metadata['plan']:'pro'"

    assert has_element?(view, "[data-testid=sub-finder-empty]")

    view |> form("[data-testid=sub-finder-form]", %{"mode" => "list"}) |> render_change()

    view
    |> form("[data-testid=sub-finder-form]", %{"mode" => "list", "customer_id" => "sub_wrong"})
    |> render_submit()

    refute_received {:stripe, "GET", "/v1/subscriptions", _params}
    assert view |> element("#flash-error") |> render() =~ "cus_"
    refute has_element?(view, "[data-testid=sub-finder-rows]")
  end

  test "metadata without = says it must be key=value, and a mode shows only its own filters",
       %{conn: conn} do
    StripeRoutes.stub(%{})
    {:ok, view, _html} = live(conn, ~p"/")
    form = "[data-testid=sub-finder-form]"

    view |> form(form, %{"mode" => "list", "customer_id" => "cus_ada"}) |> render_change()
    refute has_element?(view, "[data-testid=sub-finder-metadata]")

    view |> form(form, %{"mode" => "search"}) |> render_change()
    refute has_element?(view, "[data-testid=sub-finder-customer]")

    view |> form(form, %{"mode" => "search", "metadata" => "novalue"}) |> render_submit()
    refute_received {:stripe, "GET", "/v1/subscriptions/search", _params}
    assert view |> element("#flash-error") |> render() =~ "key=value"

    view |> form(form, %{"mode" => "list"}) |> render_change()
    assert has_element?(view, "[data-testid=sub-finder-customer]")
    refute has_element?(view, "[data-testid=sub-finder-customer][value]")
    refute has_element?(view, "[data-testid=sub-finder-metadata]")
  end

  defp page(items, more?), do: %{StripeRoutes.list(items) | "has_more" => more?}

  defp subscription(id, status) do
    %{
      "object" => "subscription",
      "id" => id,
      "status" => status,
      "customer" => %{"object" => "customer", "id" => "cus_ada", "email" => "ada@example.com"},
      "metadata" => %{"mishka_pay_reference" => "order-1"},
      "created" => 1_700_000_000,
      "items" => %{
        "object" => "list",
        "data" => [
          %{
            "id" => "si_1",
            "quantity" => 1,
            "current_period_start" => 1_700_000_000,
            "current_period_end" => 1_702_592_000,
            "price" => %{
              "id" => "price_pro",
              "product" => "prod_pro",
              "nickname" => "Pro",
              "unit_amount" => 900,
              "currency" => "usd",
              "recurring" => %{"interval" => "month", "interval_count" => 1}
            }
          }
        ]
      }
    }
  end
end

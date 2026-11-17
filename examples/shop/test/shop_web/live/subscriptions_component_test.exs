defmodule ShopWeb.SubscriptionsComponentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  test "the change form keeps what was picked through later changes, and previews it",
       %{conn: conn} do
    plan("team-monthly", "price_team")

    StripeRoutes.stub(%{
      {"GET", "/v1/subscriptions/sub_ada"} => subscription(),
      {"POST", "/v1/invoices/create_preview"} => preview(1900)
    })

    view = open_subscription(conn)
    form = "[data-testid=change-form]"

    view |> form(form, %{"price_id" => "price_team"}) |> render_change()
    view |> form(form, %{"proration" => "always_invoice"}) |> render_change()
    view |> form(form, %{"billing_cycle_anchor" => "now"}) |> render_change()
    view |> form(form, %{"quantity" => "2"}) |> render_change()
    assert has_element?(view, "[data-testid=change-plan] option[value=price_team][selected]")

    view |> form(form) |> render_submit()

    assert_received {:stripe, "POST", "/v1/invoices/create_preview",
                     %{"subscription_details" => details}}

    assert %{
             "proration_behavior" => "always_invoice",
             "billing_cycle_anchor" => %{"type" => "now"}
           } = details

    assert [%{"price" => "price_team", "quantity" => "2"}] = Map.values(details["items"])
  end

  test "the pause form keeps the way picked when the date changes, and sends it",
       %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/subscriptions/sub_ada"} => subscription(),
      {"POST", "/v1/subscriptions/sub_ada"} => subscription()
    })

    view = open_subscription(conn)
    form = "[data-testid=pause-form]"
    resumes = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

    view |> form(form, %{"behavior" => "keep_as_draft"}) |> render_change()
    assert has_element?(view, "[data-testid=pause-resumes-at][phx-debounce=blur]")
    view |> form(form, %{"resumes_at" => resumes}) |> render_change()

    assert has_element?(
             view,
             "[data-testid=pause-behavior] option[value=keep_as_draft][selected]"
           )

    assert has_element?(view, "[data-testid=pause-resumes-at][value='#{resumes}']")

    view |> form(form) |> render_submit()

    assert_received {:stripe, "POST", "/v1/subscriptions/sub_ada",
                     %{"pause_collection" => %{"behavior" => "keep_as_draft"}}}
  end

  defp open_subscription(conn) do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=read-subscription-form]", %{"subscription_id" => "sub_ada"})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "[data-testid=change-form]")
    view
  end

  defp plan(slug, price_id) do
    plan =
      Ash.create!(
        Shop.Catalog.Product,
        %{slug: slug, name: slug, price: "19.00", interval: :month, position: 2},
        action: :seed,
        authorize?: false
      )

    Ash.update!(plan, %{stripe_price_id: price_id}, action: :published, authorize?: false)
  end

  defp subscription do
    %{
      "object" => "subscription",
      "id" => "sub_ada",
      "status" => "active",
      "customer" => %{"object" => "customer", "id" => "cus_ada", "email" => "ada@shop.test"},
      "metadata" => %{},
      "items" => %{
        "object" => "list",
        "data" => [
          %{
            "id" => "si_1",
            "quantity" => 1,
            "current_period_start" => 1_794_000_000,
            "current_period_end" => 1_796_592_000,
            "price" => %{
              "id" => "price_pro",
              "product" => %{"id" => "prod_pro", "name" => "Pro"},
              "unit_amount" => 900,
              "currency" => "usd",
              "recurring" => %{"interval" => "month", "interval_count" => 1}
            }
          }
        ]
      }
    }
  end

  defp preview(amount) do
    %{
      "object" => "invoice",
      "id" => "upcoming_in",
      "status" => "draft",
      "currency" => "usd",
      "amount_due" => amount,
      "amount_paid" => 0,
      "total" => amount,
      "lines" => StripeRoutes.list([%{"description" => "Team plan", "amount" => amount}])
    }
  end
end

defmodule ShopWeb.PaymentLinksTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  @link %{
    "object" => "payment_link",
    "id" => "plink_1",
    "url" => "https://buy.stripe.com/test_1",
    "active" => true,
    "metadata" => %{},
    "created" => 1_790_000_000
  }

  test "an open link's change keeps the state picked while a buyer's address is made",
       %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/payment_links"} => StripeRoutes.list([@link]),
      {"POST", "/v1/payment_links/plink_1"} => Map.put(@link, "active", false)
    })

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=link-row][data-link-id=plink_1]") |> render_click()
    change = "[data-testid=link-change-form]"
    buyer = "[data-testid=link-buyer-form]"

    view |> form(change, %{active: "false"}) |> render_change()
    view |> form(change, %{inactive_message: "Sold out"}) |> render_change()
    view |> form(buyer, %{reference: "order-42"}) |> render_change()
    view |> form(buyer) |> render_submit()
    assert has_element?(view, "[data-testid=link-buyer-url]", "order-42")
    assert has_element?(view, "[data-testid=link-change-active] option[value=false][selected]")

    view |> form(change) |> render_submit()

    assert_received {:stripe, "POST", "/v1/payment_links/plink_1",
                     %{"active" => "false", "inactive_message" => "Sold out"}}

    assert has_element?(view, "[data-testid=link-row][data-active=false]")
  end
end

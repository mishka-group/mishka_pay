defmodule ShopWeb.TestClocksTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  test "the situation picked stays picked through a refresh, and is the one set up",
       %{conn: conn} do
    StripeRoutes.stub(%{
      {"POST", "/v1/test_helpers/test_clocks"} =>
        StripeRoutes.error(400, "No clocks in this test.")
    })

    {:ok, view, _html} = live(conn, ~p"/")
    form = "[data-testid=clock-start-form]"

    view |> form(form, %{scenario: "renewal_fails"}) |> render_change()
    view |> element("[data-testid=clock-refresh]") |> render_click()

    assert has_element?(
             view,
             "[data-testid=clock-start-scenario] option[value=renewal_fails][selected]"
           )

    view |> form(form) |> render_submit()

    assert_received {:stripe, "POST", "/v1/test_helpers/test_clocks",
                     %{"name" => "Monthly, card fails at renewal"}}
  end
end

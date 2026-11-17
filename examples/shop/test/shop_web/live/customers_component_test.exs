defmodule ShopWeb.CustomersComponentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  @ada %{
    "object" => "customer",
    "id" => "cus_ada",
    "email" => "ada@example.com",
    "name" => "Ada",
    "metadata" => %{}
  }

  test "Delete asks first, deletes the customer on Stripe and keeps the row, marked deleted", %{
    conn: conn
  } do
    StripeRoutes.stub(%{
      {"GET", "/v1/customers/cus_ada"} => @ada,
      {"DELETE", "/v1/customers/cus_ada"} => %{
        "object" => "customer",
        "id" => "cus_ada",
        "deleted" => true
      }
    })

    row = seed_customer()
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=customer-row][data-customer-id=cus_ada]") |> render_click()

    delete = element(view, "[data-testid=customer-delete]")
    assert render(delete) =~ "data-confirm="
    render_click(delete)

    assert_received {:stripe, "DELETE", "/v1/customers/cus_ada", _params}
    assert Ash.get!(Shop.Pay.Customer, row.id, authorize?: false).deleted_at

    assert has_element?(
             view,
             "[data-testid=customer-row][data-customer-id=cus_ada][data-deleted=true]"
           )

    assert has_element?(view, "[data-testid=customer-deleted-note]")
    refute has_element?(view, "[data-testid=customer-delete]")
    refute has_element?(view, "[data-testid=customer-edit-form]")
  end

  test "a delete Stripe refuses says so and leaves the row as it was", %{conn: conn} do
    StripeRoutes.stub(%{{"GET", "/v1/customers/cus_ada"} => @ada})
    row = seed_customer()
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=customer-row][data-customer-id=cus_ada]") |> render_click()

    view |> element("[data-testid=customer-delete]") |> render_click()

    assert_received {:stripe, "DELETE", "/v1/customers/cus_ada", _params}
    assert view |> element("#flash-error") |> render() =~ "Stripe refused the request"
    assert Ash.get!(Shop.Pay.Customer, row.id, authorize?: false).deleted_at == nil
    assert has_element?(view, "[data-testid=customer-delete]")
  end

  defp seed_customer do
    Ash.Seed.seed!(Shop.Pay.Customer, %{
      provider: "stripe",
      provider_id: "cus_ada",
      tenant: "demo",
      email: "ada@example.com",
      name: "Ada",
      metadata: %{},
      synced_at: DateTime.utc_now()
    })
  end
end

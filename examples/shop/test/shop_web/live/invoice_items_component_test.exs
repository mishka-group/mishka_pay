defmodule ShopWeb.InvoiceItemsComponentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  test "a pending item is added for a customer, listed, given one more and taken back", %{
    conn: conn
  } do
    StripeRoutes.stub(%{
      {"POST", "/v1/invoiceitems"} => item(1),
      {"GET", "/v1/invoiceitems"} => StripeRoutes.list([item(1)]),
      {"POST", "/v1/invoiceitems/ii_fee"} => item(2),
      {"DELETE", "/v1/invoiceitems/ii_fee"} => %{
        "object" => "invoiceitem",
        "id" => "ii_fee",
        "deleted" => true
      }
    })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=invoice-item-form]", %{
      "customer_id" => "cus_ada",
      "name" => "Setup fee",
      "amount" => "49.00",
      "currency" => "USD",
      "quantity" => "1"
    })
    |> render_submit()

    assert_received {:stripe, "POST", "/v1/invoiceitems", made}

    assert %{
             "customer" => "cus_ada",
             "description" => "Setup fee",
             "currency" => "usd",
             "unit_amount_decimal" => "4900",
             "quantity" => "1",
             "metadata" => %{"mishka_pay_reference" => "item-" <> _}
           } = made

    refute Map.has_key?(made, "invoice")

    assert_received {:stripe, "GET", "/v1/invoiceitems", listed}
    assert %{"customer" => "cus_ada", "pending" => "true"} = listed

    assert has_element?(view, "[data-testid=invoice-item-row][data-item-id=ii_fee]")
    assert view |> element("[data-testid=invoice-item-row-total]") |> render() =~ "49.00"

    view |> element("[data-testid=invoice-item-more]") |> render_click()
    assert_received {:stripe, "POST", "/v1/invoiceitems/ii_fee", %{"quantity" => "2"}}
    assert view |> element("[data-testid=invoice-item-row-quantity]") |> render() =~ "2"

    delete = element(view, "[data-testid=invoice-item-delete]")
    assert render(delete) =~ "data-confirm="
    render_click(delete)

    assert_received {:stripe, "DELETE", "/v1/invoiceitems/ii_fee", _params}
    refute has_element?(view, "[data-testid=invoice-item-row]")
  end

  test "Show waiting lists the picked customer's items, and a missing customer says so", %{
    conn: conn
  } do
    StripeRoutes.stub(%{})
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("[data-testid=invoice-item-show]") |> render_click()
    refute_received {:stripe, "GET", "/v1/invoiceitems", _params}
    assert view |> element("#flash-error") |> render() =~ "Pick a customer"

    view
    |> form("[data-testid=invoice-item-form]", %{"customer_id" => "cus_ada"})
    |> render_change()

    view |> element("[data-testid=invoice-item-show]") |> render_click()

    assert_received {:stripe, "GET", "/v1/invoiceitems", %{"customer" => "cus_ada"}}
    assert has_element?(view, "[data-testid=invoice-item-empty]")
  end

  defp item(quantity) do
    %{
      "object" => "invoiceitem",
      "id" => "ii_fee",
      "customer" => "cus_ada",
      "invoice" => nil,
      "currency" => "usd",
      "amount" => 4_900 * quantity,
      "quantity" => quantity,
      "description" => "Setup fee",
      "pricing" => %{"type" => "price_details", "unit_amount_decimal" => "4900"},
      "metadata" => %{}
    }
  end
end

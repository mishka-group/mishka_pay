defmodule ShopWeb.AdminRowsTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  @now 1_790_000_000

  defp product(name),
    do: %{
      "id" => "prod_1",
      "object" => "product",
      "name" => name,
      "active" => true,
      "created" => @now
    }

  defp invoice(status) do
    %{
      "id" => "in_1",
      "object" => "invoice",
      "status" => status,
      "customer" => "cus_1",
      "currency" => "usd",
      "total" => 5000,
      "amount_due" => 5000,
      "amount_paid" => 0,
      "collection_method" => "send_invoice",
      "number" => if(status == "draft", do: nil, else: "ABC-0001"),
      "created" => @now
    }
  end

  test "adds a product, reads it again, and archives it", %{conn: conn} do
    StripeStub.stub(fn
      "POST", "/v1/products", %{"name" => name} ->
        product(name)

      "GET", "/v1/products/prod_1", _params ->
        product("Renamed on Stripe")

      "POST", "/v1/products/prod_1", %{"active" => "false"} ->
        Map.put(product("Renamed on Stripe"), "active", false)

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("[data-testid=admin-add-form]", %{name: "Elixir ebook", tax_code: ""})
    |> render_submit()

    assert has_element?(view, "[data-testid=admin-notice]", "prod_1")
    assert has_element?(view, "[data-testid=admin-row][data-provider-id=prod_1]", "Elixir ebook")

    view |> element("[data-provider-id=prod_1] [data-testid=admin-resync]") |> render_click()

    assert has_element?(
             view,
             "[data-testid=admin-row][data-provider-id=prod_1]",
             "Renamed on Stripe"
           )

    view |> element("[data-provider-id=prod_1] [data-testid=admin-archive]") |> render_click()
    assert has_element?(view, "[data-provider-id=prod_1] [data-testid=admin-row-state]", "off")
    refute has_element?(view, "[data-provider-id=prod_1] [data-testid=admin-archive]")
  end

  test "adds a price and shows its amount", %{conn: conn} do
    StripeStub.stub(fn
      "POST", "/v1/prices", %{"product" => "prod_1", "unit_amount" => "999"} ->
        %{
          "id" => "price_1",
          "object" => "price",
          "product" => "prod_1",
          "unit_amount" => 999,
          "currency" => "usd",
          "active" => true,
          "recurring" => %{"interval" => "month", "interval_count" => 1}
        }

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")
    view |> element("[data-testid=admin-tab-price]") |> render_click()

    view
    |> form("[data-testid=admin-add-form]", %{
      product_id: "prod_1",
      amount: "9.99",
      currency: "USD",
      interval: "month"
    })
    |> render_submit()

    assert has_element?(
             view,
             "[data-provider-id=price_1] [data-testid=admin-row-amount]",
             "$9.99"
           )

    assert has_element?(
             view,
             "[data-provider-id=price_1] [data-testid=admin-row-what]",
             "every month"
           )
  end

  test "makes a bill, finalizes it, and marks it paid out of band", %{conn: conn} do
    StripeStub.stub(fn
      "POST", "/v1/invoices", %{"customer" => "cus_1"} -> invoice("draft")
      "POST", "/v1/invoiceitems", %{"invoice" => "in_1"} -> %{"id" => "ii_1"}
      "GET", "/v1/invoices/in_1", _params -> invoice("draft")
      "POST", "/v1/invoices/in_1/finalize", _params -> invoice("open")
      "POST", "/v1/invoices/in_1/pay", %{"paid_out_of_band" => "true"} -> invoice("paid")
      _method, _path, _params -> nil
    end)

    {:ok, view, _html} = live(conn, "/")
    view |> element("[data-testid=admin-tab-invoice]") |> render_click()

    view
    |> form("[data-testid=admin-add-form]", %{
      customer_id: "cus_1",
      item: "Setup work",
      amount: "50.00",
      currency: "USD",
      collection: "send_invoice"
    })
    |> render_submit()

    assert has_element?(view, "[data-provider-id=in_1] [data-testid=admin-row-state]", "draft")
    assert has_element?(view, "[data-provider-id=in_1] [data-testid=admin-row-amount]", "$50.00")

    view |> element("[data-provider-id=in_1] [data-testid=admin-finalize]") |> render_click()
    assert has_element?(view, "[data-provider-id=in_1] [data-testid=admin-row-state]", "open")
    assert has_element?(view, "[data-provider-id=in_1] [data-testid=admin-send]")
    assert has_element?(view, "[data-provider-id=in_1] [data-testid=admin-void]")

    view |> element("[data-provider-id=in_1] [data-testid=admin-pay]") |> render_click()
    assert has_element?(view, "[data-provider-id=in_1] [data-testid=admin-row-state]", "paid")
    assert has_element?(view, "[data-testid=admin-notice]", "paid out of band")
  end

  test "shows Stripe's refusal in plain words", %{conn: conn} do
    StripeStub.stub(fn
      "POST", "/v1/coupons", _params ->
        StripeStub.error("Invalid percent_off: must be at most 100")

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")
    view |> element("[data-testid=admin-tab-coupon]") |> render_click()

    view
    |> form("[data-testid=admin-add-form]", %{percent_off: "150", duration: "once"})
    |> render_submit()

    assert has_element?(view, "[data-testid=admin-error]")
    assert has_element?(view, "[data-testid=admin-rows-empty]")
  end
end

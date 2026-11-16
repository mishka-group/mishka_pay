defmodule ShopWeb.BillsComponentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  test "a bill is made, finalized, emailed and marked paid, showing each step", %{conn: conn} do
    stub_bill()
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=bill-form]", %{
      "customer_id" => "cus_ada",
      "item_name" => "Consulting",
      "item_amount" => "120.00",
      "item_quantity" => "2",
      "collection" => "send_invoice",
      "days_until_due" => "14"
    })
    |> render_submit()

    assert_received {:stripe, "POST", "/v1/invoices", draft}
    assert draft["customer"] == "cus_ada"
    assert draft["collection_method"] == "send_invoice"
    assert draft["days_until_due"] == "14"
    assert_received {:stripe, "POST", "/v1/invoiceitems", item}
    assert item["invoice"] == "in_bill"
    assert item["quantity"] == "2"

    assert view |> element("[data-testid=bill-status]") |> render() =~ "draft"
    refute has_element?(view, "[data-testid=bill-hosted-link]")

    view |> element("[data-testid=bill-finalize]") |> render_click()

    assert view |> element("[data-testid=bill-status]") |> render() =~ "open"
    assert view |> element("[data-testid=bill-number]") |> render() =~ "SHOP-0001"

    assert has_element?(
             view,
             ~s|[data-testid=bill-hosted-link][href="https://invoice.stripe.com/i/in_bill"]|
           )

    assert has_element?(
             view,
             ~s|[data-testid=bill-pdf-link][href="https://pay.stripe.com/invoice/in_bill/pdf"]|
           )

    view |> element("[data-testid=bill-send]") |> render_click()
    assert_received {:stripe, "POST", "/v1/invoices/in_bill/send", _params}

    view |> element("[data-testid=bill-pay_out_of_band]") |> render_click()
    assert_received {:stripe, "POST", "/v1/invoices/in_bill/pay", %{"paid_out_of_band" => "true"}}

    assert view |> element("[data-testid=bill-status]") |> render() =~ "paid"
    refute has_element?(view, "[data-testid=bill-void]")

    statuses =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-testid=bill-step]")
      |> LazyHTML.attribute("data-status")

    assert statuses == ["draft", "open", "open", "paid"]
  end

  test "an open bill is voided or marked uncollectible", %{conn: conn} do
    stub_bill()
    {:ok, view, _html} = live(conn, ~p"/")
    make_and_open(view)

    view |> element("[data-testid=bill-uncollectible]") |> render_click()
    assert view |> element("[data-testid=bill-status]") |> render() =~ "uncollectible"

    view |> element("[data-testid=bill-void]") |> render_click()
    assert view |> element("[data-testid=bill-status]") |> render() =~ "void"
    refute has_element?(view, "[data-testid=bill-pay_out_of_band]")
  end

  test "a draft is deleted", %{conn: conn} do
    stub_bill()
    {:ok, view, _html} = live(conn, ~p"/")
    view |> form("[data-testid=bill-form]", customer_id: "cus_ada") |> render_submit()

    view |> element("[data-testid=bill-delete]") |> render_click()

    assert_received {:stripe, "DELETE", "/v1/invoices/in_bill", _params}
    assert has_element?(view, "[data-testid=bill-deleted]")
    refute has_element?(view, "[data-testid=bill-card]")
  end

  test "Stripe's refusal (merchant of record on) is shown in plain words", %{conn: conn} do
    StripeRoutes.stub(%{
      {"POST", "/v1/invoices"} =>
        StripeRoutes.error(400, "Invoices are not supported when Managed Payments is enabled.")
    })

    {:ok, view, _html} = live(conn, ~p"/")
    view |> form("[data-testid=bill-form]", customer_id: "cus_ada") |> render_submit()

    refute has_element?(view, "[data-testid=bill-card]")
    assert render(view) =~ "merchant of record"
  end

  test "no customer is refused before Stripe is asked", %{conn: conn} do
    StripeRoutes.stub(%{})
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("[data-testid=bill-form]") |> render_submit()

    refute_received {:stripe, "POST", "/v1/invoices", _params}
    assert render(view) =~ "Pick a customer"
  end

  defp make_and_open(view) do
    view |> form("[data-testid=bill-form]", customer_id: "cus_ada") |> render_submit()
    view |> element("[data-testid=bill-finalize]") |> render_click()
  end

  defp stub_bill do
    StripeRoutes.stub(%{
      {"POST", "/v1/invoices"} => invoice("draft"),
      {"POST", "/v1/invoiceitems"} => %{"object" => "invoiceitem", "id" => "ii_1"},
      {"GET", "/v1/invoices/in_bill"} => invoice("draft"),
      {"POST", "/v1/invoices/in_bill/finalize"} => invoice("open"),
      {"POST", "/v1/invoices/in_bill/send"} => invoice("open"),
      {"POST", "/v1/invoices/in_bill/pay"} => invoice("paid"),
      {"POST", "/v1/invoices/in_bill/void"} => invoice("void"),
      {"POST", "/v1/invoices/in_bill/mark_uncollectible"} => invoice("uncollectible"),
      {"DELETE", "/v1/invoices/in_bill"} => %{"id" => "in_bill", "deleted" => true}
    })
  end

  defp invoice(status) do
    open? = status != "draft"

    %{
      "object" => "invoice",
      "id" => "in_bill",
      "status" => status,
      "customer" => "cus_ada",
      "currency" => "usd",
      "amount_due" => 24_000,
      "amount_paid" => if(status == "paid", do: 24_000, else: 0),
      "total" => 24_000,
      "collection_method" => "send_invoice",
      "number" => open? && "SHOP-0001",
      "hosted_invoice_url" => open? && "https://invoice.stripe.com/i/in_bill",
      "invoice_pdf" => open? && "https://pay.stripe.com/invoice/in_bill/pdf"
    }
    |> Map.reject(fn {_key, value} -> value == false end)
  end
end

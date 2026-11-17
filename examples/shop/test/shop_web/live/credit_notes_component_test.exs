defmodule ShopWeb.CreditNotesComponentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  test "a line of an open bill is previewed, credited once, listed with its lines and voided",
       %{conn: conn} do
    stub_notes("open")
    {:ok, view, _html} = live(conn, ~p"/")
    make_bill(view)

    refute has_element?(view, "[data-testid=credit-note-form]")
    view |> element("[data-testid=credit-note-open]") |> render_click()
    refute_received {:stripe, "GET", "/v1/credit_notes" <> _, _params}
    refute has_element?(view, "[data-testid=credit-note-create]")

    note_form(view, %{"what" => "il_seat"}) |> render_change()

    note_form(view, %{"what" => "il_seat", "quantity" => "1", "reason" => "order_change"})
    |> render_submit(%{"do" => "preview"})

    assert_received {:stripe, "GET", "/v1/credit_notes/preview", preview}

    assert %{
             "invoice" => "in_bill",
             "reason" => "order_change",
             "lines" => %{"0" => %{"invoice_line_item" => "il_seat", "quantity" => "1"}}
           } = preview

    assert view |> element("[data-testid=credit-note-preview-amount]") |> render() =~ "$30.00"

    note_form(view, %{"what" => "il_seat", "quantity" => "1", "reason" => "order_change"})
    |> render_submit(%{"do" => "create"})

    assert_received {:stripe, "POST", "/v1/credit_notes", made}
    assert made["lines"] == preview["lines"]
    assert "credit-in_bill-" <> _ = made["metadata"]["mishka_pay_reference"]
    refute Map.has_key?(made, "out_of_band_amount")
    assert view |> element("[data-testid=bill-result]") |> render() =~ "Read again"

    assert has_element?(
             view,
             "[data-testid=credit-note-row][data-note-id=cn_1][data-status=issued]"
           )

    refute has_element?(view, "[data-testid=credit-note-create]")

    view |> element("[data-testid=credit-note-show]") |> render_click()
    render_async(view)
    assert_received {:stripe, "GET", "/v1/credit_notes", %{"invoice" => "in_bill"}}

    view |> element("[data-testid=credit-note-lines-button]") |> render_click()
    render_async(view)
    assert_received {:stripe, "GET", "/v1/credit_notes/cn_1/lines", _params}
    assert has_element?(view, "[data-testid=credit-note-line][data-type=invoice_line]")

    view |> element("[data-testid=credit-note-void]") |> render_click()
    assert_received {:stripe, "POST", "/v1/credit_notes/cn_1/void", _params}

    assert has_element?(
             view,
             "[data-testid=credit-note-row][data-note-id=cn_1][data-status=void]"
           )
  end

  test "an amount of a paid bill goes where the form says, and its note cannot be voided",
       %{conn: conn} do
    stub_notes("paid")
    {:ok, view, _html} = live(conn, ~p"/")
    make_bill(view)
    assert view |> element("[data-testid=bill-status]") |> render() =~ "paid"
    view |> element("[data-testid=credit-note-open]") |> render_click()

    fields = %{"what" => "amount", "amount" => "30.00", "money_to" => "credit_amount"}
    note_form(view, fields) |> render_submit(%{"do" => "preview"})
    assert_received {:stripe, "GET", "/v1/credit_notes/preview", %{"amount" => "3000"} = preview}
    refute Map.has_key?(preview, "credit_amount")

    note_form(view, fields) |> render_submit(%{"do" => "create"})
    assert_received {:stripe, "POST", "/v1/credit_notes", made}
    assert %{"amount" => "3000", "credit_amount" => "3000"} = made

    refute has_element?(view, "[data-testid=credit-note-void]")
    assert has_element?(view, "[data-testid=credit-note-void-closed]")
  end

  test "a changed form is previewed again, and Stripe's refusal is shown", %{conn: conn} do
    stub_notes("open",
      preview:
        StripeRoutes.error(
          400,
          "The credit note amount ($900.00) must not exceed the remaining creditable amount."
        )
    )

    {:ok, view, _html} = live(conn, ~p"/")
    make_bill(view)
    view |> element("[data-testid=credit-note-open]") |> render_click()

    note_form(view, %{"what" => "amount", "amount" => "900"})
    |> render_submit(%{"do" => "preview"})

    refute has_element?(view, "[data-testid=credit-note-preview-card]")
    refute has_element?(view, "[data-testid=credit-note-create]")
    assert view |> element("#flash-error") |> render() =~ "Stripe"
    refute_received {:stripe, "POST", "/v1/credit_notes", _params}
  end

  defp note_form(view, fields), do: form(view, "[data-testid=credit-note-form]", fields)

  # Stripe reads the new bill back in the status the test gives it.
  defp make_bill(view),
    do: view |> form("[data-testid=bill-form]", customer_id: "cus_ada") |> render_submit()

  defp stub_notes(status, opts \\ []) do
    StripeRoutes.stub(%{
      {"POST", "/v1/invoices"} => invoice("draft"),
      {"POST", "/v1/invoiceitems"} => %{"object" => "invoiceitem", "id" => "ii_1"},
      {"GET", "/v1/invoices/in_bill"} => invoice(status),
      {"GET", "/v1/credit_notes/preview"} => Keyword.get(opts, :preview, note("issued")),
      {"POST", "/v1/credit_notes"} => note("issued"),
      {"GET", "/v1/credit_notes"} => StripeRoutes.list([note("issued")]),
      {"GET", "/v1/credit_notes/cn_1"} => note("issued"),
      {"GET", "/v1/credit_notes/cn_1/lines"} => StripeRoutes.list([line()]),
      {"POST", "/v1/credit_notes/cn_1/void"} => note("void")
    })
  end

  defp invoice(status) do
    %{
      "object" => "invoice",
      "id" => "in_bill",
      "status" => status,
      "customer" => "cus_ada",
      "currency" => "usd",
      "amount_due" => 6_000,
      "amount_paid" => if(status == "paid", do: 6_000, else: 0),
      "total" => 6_000,
      "collection_method" => "send_invoice",
      "lines" => %{
        "data" => [
          %{"id" => "il_seat", "description" => "Seat", "amount" => 6_000, "quantity" => 2}
        ]
      }
    }
  end

  defp note(status) do
    %{
      "object" => "credit_note",
      "id" => "cn_1",
      "number" => "SHOP-0001-CN-01",
      "invoice" => "in_bill",
      "customer" => "cus_ada",
      "currency" => "usd",
      "amount" => 3_000,
      "status" => status,
      "type" => "pre_payment",
      "reason" => "order_change",
      "lines" => StripeRoutes.list([line()])
    }
  end

  defp line do
    %{
      "object" => "credit_note_line_item",
      "id" => "cnli_1",
      "type" => "invoice_line_item",
      "invoice_line_item" => "il_seat",
      "quantity" => 1,
      "amount" => 3_000
    }
  end
end

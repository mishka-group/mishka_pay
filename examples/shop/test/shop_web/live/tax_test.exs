defmodule ShopWeb.TaxTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  defp tax_id do
    MishkaPay.Test.stripe_object(:tax_id, %{
      "id" => "txi_1",
      "customer" => "cus_1",
      "verification" => %{"status" => "verified", "verified_name" => "Test GmbH"}
    })
  end

  test "adds a customer's EU VAT id, lists it with its check, and removes it", %{conn: conn} do
    test = self()

    StripeStub.stub(fn
      "POST", "/v1/customers/cus_1/tax_ids", %{"type" => "eu_vat", "value" => "DE123456789"} ->
        tax_id()

      "GET", "/v1/customers/cus_1/tax_ids", _params ->
        if Process.get(:deleted), do: StripeStub.list([]), else: StripeStub.list([tax_id()])

      "DELETE", "/v1/customers/cus_1/tax_ids/txi_1", _params ->
        Process.put(:deleted, true)
        send(test, :deleted)
        %{"id" => "txi_1", "deleted" => true}

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("[data-testid=tax-ids-form]", %{
      customer_id: "cus_1",
      type: "eu_vat",
      value: "DE123456789"
    })
    |> render_submit(%{intent: "add"})

    assert has_element?(view, "[data-testid=tax-notice]", "verified")
    assert has_element?(view, "[data-tax-id=txi_1] [data-testid=tax-id-verification]", "verified")

    view |> element("[data-tax-id=txi_1] [data-testid=tax-id-delete]") |> render_click()
    assert_received :deleted
    assert has_element?(view, "[data-testid=tax-ids-empty]")
  end

  test "both forms keep what was picked while the other one shows its answer", %{conn: conn} do
    test = self()

    StripeStub.stub(fn
      "POST", "/v1/customers/cus_1/tax_ids", params ->
        send(test, {:tax_id, params})
        tax_id()

      "GET", "/v1/customers/cus_1/tax_ids", _params ->
        StripeStub.list([tax_id()])

      "POST", "/v1/tax/calculations", params ->
        send(test, {:calculated, params})
        nil

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")
    ids = "[data-testid=tax-ids-form]"
    calc = "[data-testid=tax-calc-form]"

    view |> form(calc, %{currency: "GBP"}) |> render_change()
    view |> form(calc, %{country: "GB"}) |> render_change()
    view |> form(ids, %{type: "gb_vat"}) |> render_change()
    view |> form(ids, %{customer_id: "cus_1", value: "GB123456789"}) |> render_change()
    view |> form(ids) |> render_submit(%{intent: "list"})
    assert has_element?(view, "[data-testid=tax-calc-country] option[value=GB][selected]")

    view |> form(calc) |> render_submit()

    assert_received {:calculated,
                     %{
                       "currency" => "gbp",
                       "customer_details" => %{"address" => %{"country" => "GB"}}
                     }}

    view |> form(ids) |> render_submit(%{intent: "add"})
    assert_received {:tax_id, %{"type" => "gb_vat", "value" => "GB123456789"}}
  end

  test "counts the tax on a sale and records it", %{conn: conn} do
    StripeStub.stub(fn
      "POST", "/v1/tax/calculations", %{"currency" => "eur", "line_items" => %{"0" => line}} ->
        %{
          "id" => "taxcalc_1",
          "currency" => "eur",
          "amount_total" => String.to_integer(line["amount"]) + 570,
          "tax_amount_exclusive" => 570,
          "tax_amount_inclusive" => 0,
          "customer_details" => %{"address" => %{"country" => "DE"}},
          "line_items" => %{
            "data" => [
              %{
                "id" => "tax_li_1",
                "reference" => line["reference"],
                "amount" => String.to_integer(line["amount"]),
                "quantity" => 1,
                "amount_tax" => 570
              }
            ]
          }
        }

      "POST",
      "/v1/tax/transactions/create_from_calculation",
      %{"calculation" => "taxcalc_1"} = p ->
        %{"id" => "tax_1", "reference" => p["reference"]}

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("[data-testid=tax-calc-form]", %{amount: "30.00", currency: "EUR", country: "DE"})
    |> render_submit()

    assert has_element?(view, "[data-testid=tax-calc-total]", "35.70")
    assert has_element?(view, "[data-testid=tax-calc-tax]", "5.70")

    view
    |> form("[data-testid=tax-record-form]", %{reference: "order-42"})
    |> render_submit()

    assert has_element?(view, "[data-testid=tax-record-result]", "tax_1")
    assert has_element?(view, "[data-testid=tax-record-result]", "order-42")
  end

  test "shows Stripe's answer when Stripe Tax is off", %{conn: conn} do
    StripeStub.stub(fn
      "POST", "/v1/tax/calculations", _params ->
        StripeStub.error(
          "Stripe Tax has not been activated on your account.",
          "stripe_tax_inactive"
        )

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("[data-testid=tax-calc-form]", %{amount: "30.00", currency: "EUR", country: "DE"})
    |> render_submit()

    assert has_element?(view, "[data-testid=tax-error]")
    refute has_element?(view, "[data-testid=tax-calc-result]")
  end
end

defmodule ShopWeb.BalanceTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  defp movement(id),
    do: %{
      "id" => id,
      "amount" => 2000,
      "fee" => 88,
      "net" => 1912,
      "currency" => "usd",
      "type" => "charge",
      "status" => "available",
      "created" => 1_790_000_000
    }

  test "reads the balance and its movements page by page", %{conn: conn} do
    StripeStub.stub(fn
      "GET", "/v1/balance", _params ->
        %{
          "available" => [%{"amount" => 12_345, "currency" => "usd"}],
          "pending" => [%{"amount" => 500, "currency" => "usd"}]
        }

      "GET", "/v1/balance_transactions", %{"starting_after" => "txn_1"} ->
        StripeStub.list([movement("txn_2")])

      "GET", "/v1/balance_transactions", _params ->
        Map.put(StripeStub.list([movement("txn_1")]), "has_more", true)

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")

    view |> element("[data-testid=balance-read]") |> render_click()
    assert has_element?(view, "[data-testid=balance-available]", "$123.45")
    assert has_element?(view, "[data-testid=balance-pending]", "$5.00")

    view |> element("[data-testid=balance-movements]") |> render_click()

    assert has_element?(
             view,
             "[data-movement-id=txn_1] [data-testid=balance-movement-net]",
             "$19.12"
           )

    view |> element("[data-testid=balance-movements-more]") |> render_click()
    assert has_element?(view, "[data-testid=balance-movement-row][data-movement-id=txn_2]")
    refute has_element?(view, "[data-testid=balance-movements-more]")
  end

  test "gives a customer credit and lists the change", %{conn: conn} do
    test = self()

    change = %{
      "id" => "cbtxn_1",
      "customer" => "cus_1",
      "amount" => -500,
      "ending_balance" => -500,
      "currency" => "usd",
      "description" => "Sorry for the wait",
      "type" => "adjustment"
    }

    StripeStub.stub(fn
      "POST", "/v1/customers/cus_1/balance_transactions", %{"amount" => amount} ->
        send(test, {:adjusted, amount})
        change

      "GET", "/v1/customers/cus_1/balance_transactions", _params ->
        StripeStub.list([change])

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("[data-testid=customer-balance-form]", %{
      customer_id: "cus_1",
      direction: "credit",
      amount: "5.00",
      currency: "USD",
      description: "Sorry for the wait"
    })
    |> render_submit(%{intent: "adjust"})

    assert_received {:adjusted, "-500"}
    assert has_element?(view, "[data-testid=balance-notice]", "-$5.00")
    assert has_element?(view, "[data-testid=customer-balance-row][data-change-id=cbtxn_1]")
  end

  test "the way and the currency picked stay picked through a change and a listing",
       %{conn: conn} do
    test = self()

    StripeStub.stub(fn
      "POST", "/v1/customers/cus_1/balance_transactions", params ->
        send(test, {:adjusted, params})

        %{
          "id" => "cbtxn_2",
          "customer" => "cus_1",
          "amount" => 700,
          "ending_balance" => 700,
          "currency" => "eur",
          "type" => "adjustment"
        }

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")
    form = "[data-testid=customer-balance-form]"

    view |> form(form, %{customer_id: "cus_1"}) |> render_change()
    view |> form(form, %{direction: "debit"}) |> render_change()
    view |> form(form, %{currency: "EUR"}) |> render_change()
    view |> form(form, %{amount: "7.00"}) |> render_change()
    view |> form(form) |> render_submit(%{intent: "list"})

    assert has_element?(
             view,
             "[data-testid=customer-balance-currency] option[value=EUR][selected]"
           )

    view |> form(form) |> render_submit(%{intent: "adjust"})

    assert_received {:adjusted, %{"amount" => "700", "currency" => "eur"}}
  end
end

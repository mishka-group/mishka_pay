defmodule ShopWeb.CurrenciesTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  # Stripe's answer is the price it was sent, so what the page shows is how Mishka Pay counts.
  defp price(params) do
    %{
      "id" => "price_c1",
      "object" => "price",
      "product" => params["product"],
      "unit_amount" => String.to_integer(params["unit_amount"]),
      "currency" => params["currency"],
      "active" => true
    }
  end

  setup do
    test = self()

    StripeStub.stub(fn
      "POST", "/v1/products", %{"name" => "Currency demo"} ->
        %{"id" => "prod_c1", "object" => "product", "name" => "Currency demo", "active" => true}

      "POST", "/v1/prices", params ->
        send(test, {:sent, params["currency"], params["unit_amount"], params["product"]})
        Process.put(:price, price(params))
        price(params)

      "GET", "/v1/prices/price_c1", _params ->
        Process.get(:price)

      _method, _path, _params ->
        nil
    end)

    :ok
  end

  for {currency, amount, minor} <- [
        {"ISK", "1500", "150000"},
        {"UGX", "5000", "500000"},
        {"MGA", "10000", "10000"},
        {"HUF", "1990", "199000"}
      ] do
    test "makes a price in #{currency} and reads the same amount back", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> form("[data-testid=currencies-form]", %{
        currency: unquote(currency),
        amount: unquote(amount),
        product_id: ""
      })
      |> render_submit()

      lower = String.downcase(unquote(currency))
      assert_received {:sent, ^lower, unquote(minor), "prod_c1"}
      assert has_element?(view, "[data-testid=currencies-price-id]", "price_c1")
      assert has_element?(view, "[data-testid=currencies-same]", "yes")
    end
  end

  test "refuses a fraction of a krona before asking Stripe", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> form("[data-testid=currencies-form]", %{
      currency: "ISK",
      amount: "10.50",
      product_id: "prod_1"
    })
    |> render_submit()

    assert has_element?(view, "[data-testid=currencies-error]")
    refute_received {:sent, _currency, _amount, _product}
  end

  test "the currency picked stays picked after a price is made, and the next one sends it",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    form = "[data-testid=currencies-form]"

    view |> form(form, %{currency: "MGA"}) |> render_change()
    view |> form(form, %{amount: "10000"}) |> render_change()
    view |> form(form) |> render_submit()
    assert_received {:sent, "mga", "10000", "prod_c1"}
    assert has_element?(view, "[data-testid=currencies-currency] option[value=MGA][selected]")

    view |> form(form) |> render_submit()
    assert_received {:sent, "mga", "10000", "prod_c1"}
  end
end

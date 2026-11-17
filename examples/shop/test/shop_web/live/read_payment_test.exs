defmodule ShopWeb.ReadPaymentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  test "a payment Stripe does not have shows its plain words and, apart, Stripe's request id", %{
    conn: conn
  } do
    StripeRoutes.stub(%{
      {"GET", "/v1/payment_intents/pi_gone"} =>
        {404,
         %{
           "error" => %{
             "type" => "invalid_request_error",
             "code" => "resource_missing",
             "doc_url" => "https://stripe.com/docs/error-codes/resource-missing",
             "message" => "No such payment_intent: 'pi_gone'"
           }
         }}
    })

    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "[data-testid=request-id]")

    html =
      view |> form("[data-testid=read-payment-form]", payment_id: "pi_gone") |> render_submit()

    assert view |> element("[data-testid=request-id-value]") |> render() =~ "req_shop_test"

    assert view |> element("[data-testid=request-id-doc]") |> render() =~
             "stripe.com/docs/error-codes/resource-missing"

    flash = view |> element("#flash-error") |> render()
    assert flash =~ "Stripe has nothing with the id given"
    refute flash =~ "req_shop_test"
    assert html =~ "request id"
  end
end

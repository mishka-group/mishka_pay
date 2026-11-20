defmodule ShopWeb.CheckoutReturnTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  test "one return page reads Stripe's session from the provider's own query", %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/checkout/sessions/cs_test_back"} => %{
        "object" => "checkout.session",
        "id" => "cs_test_back",
        "status" => "complete",
        "customer" => "cus_ada",
        "setup_intent" => %{"id" => "seti_1", "payment_method" => "pm_visa"}
      }
    })

    {:ok, view, _html} = live(conn, ~p"/?provider=stripe&session_id=cs_test_back")
    assert render_async(view) =~ "Card saved"
    assert_received {:stripe, "GET", "/v1/checkout/sessions/cs_test_back", _params}
  end

  test "the same page reads PayPal's Order from its token", %{conn: conn} do
    MishkaPay.Test.put_keys(
      "paypal",
      %{publishable_key: "client_d", secret_key: "secret_d", mode: :test},
      "demo"
    )

    StripeRoutes.stub(%{})
    MishkaPay.Test.PayPal.stub!()
    MishkaPay.Test.PayPal.order("ORDERBACK1", "CREATED")

    # PayPal's stand-in answers PayPal; the page's Stripe lists are empty.
    MishkaPay.Test.stub_http(fn
      %{host: "api-m.sandbox.paypal.com"} = conn -> MishkaPay.Test.PayPal.forward(conn)
      conn -> Req.Test.json(conn, StripeRoutes.list([]))
    end)

    {:ok, view, _html} = live(conn, ~p"/?provider=paypal&token=ORDERBACK1&PayerID=P1")
    render_async(view)

    assert_received {:paypal, "GET", "/v2/checkout/orders/ORDERBACK1", _headers, _body}
  end

  test "a return naming no checkout says so in plain words", %{conn: conn} do
    StripeRoutes.stub(%{})
    {:ok, view, _html} = live(conn, ~p"/?provider=stripe")
    assert render(view) =~ "names no checkout"
  end
end

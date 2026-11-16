defmodule ShopWeb.PaymentToolsComponentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  @refund %{
    "object" => "refund",
    "id" => "re_one",
    "amount" => 500,
    "currency" => "usd",
    "status" => "succeeded",
    "reason" => "requested_by_customer",
    "payment_intent" => "pi_paid",
    "created" => 1_790_000_000
  }

  test "Refunds on a payment row lists every refund Stripe made on it", %{conn: conn} do
    StripeStub.stub(%{{"GET", "/v1/refunds"} => StripeStub.list([@refund])})
    seed_payment("pi_paid", :partially_refunded)
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element(
      "[data-testid=payment-tools-row][data-payment-id=pi_paid] [data-testid=payment-refunds]"
    )
    |> render_click()

    assert_received {:stripe, "GET", "/v1/refunds", %{"payment_intent" => "pi_paid"}}
    assert has_element?(view, "[data-testid=refund-list][data-payment-id=pi_paid]")

    assert view |> element("[data-testid=refund-item][data-refund-id=re_one]") |> render() =~
             "$5.00"
  end

  test "a payment with no refunds says so", %{conn: conn} do
    StripeStub.stub(%{{"GET", "/v1/refunds"} => StripeStub.list([])})
    seed_payment("pi_paid", :paid)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("[data-testid=payment-refunds]") |> render_click()

    assert has_element?(view, "[data-testid=refund-list-empty]")
  end

  test "one refund is read by its id, and a payment id is refused in plain words",
       %{conn: conn} do
    StripeStub.stub(%{{"GET", "/v1/refunds/re_one"} => @refund})
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("[data-testid=read-refund-form]", refund_id: "re_one") |> render_submit()

    assert view |> element("[data-testid=refund-card-status]") |> render() =~ "succeeded"
    assert view |> element("[data-testid=refund-card-amount]") |> render() =~ "$5.00"

    view |> form("[data-testid=read-refund-form]", refund_id: "pi_paid") |> render_submit()

    assert render(view) =~ "That is a payment id"
    refute has_element?(view, "[data-testid=refund-card]")
  end

  test "only a held payment offers Capture and Cancel", %{conn: conn} do
    StripeStub.stub(%{})
    seed_payment("pi_paid", :paid)
    seed_payment("pi_held", :authorized)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "[data-payment-id=pi_held] [data-testid=capture-form]")
    assert has_element?(view, "[data-payment-id=pi_held] [data-testid=capture-cancel]")
    refute has_element?(view, "[data-payment-id=pi_paid] [data-testid=capture-form]")
  end

  test "capturing part of a held payment sends that part, and the row turns paid",
       %{conn: conn} do
    StripeStub.stub(%{
      {"GET", "/v1/payment_intents/pi_held"} => intent("pi_held", "requires_capture"),
      {"POST", "/v1/payment_intents/pi_held/capture"} => intent("pi_held", "succeeded", 500),
      {"GET", "/v1/checkout/sessions"} => StripeStub.list([])
    })

    seed_payment("pi_held", :authorized)
    {:ok, view, _html} = live(conn, ~p"/")

    stub_after_capture()

    view
    |> form("[data-payment-id=pi_held] [data-testid=capture-form]", amount: "5.00")
    |> render_submit()

    assert_received {:stripe, "POST", "/v1/payment_intents/pi_held/capture",
                     %{"amount_to_capture" => "500"}}

    assert has_element?(
             view,
             "[data-testid=payment-tools-row][data-payment-id=pi_held][data-status=paid]"
           )

    refute has_element?(view, "[data-payment-id=pi_held] [data-testid=capture-form]")
  end

  test "capturing more than was held is refused before Stripe is asked", %{conn: conn} do
    StripeStub.stub(%{
      {"GET", "/v1/payment_intents/pi_held"} => intent("pi_held", "requires_capture")
    })

    seed_payment("pi_held", :authorized)
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-payment-id=pi_held] [data-testid=capture-form]", amount: "50.00")
    |> render_submit()

    refute_received {:stripe, "POST", "/v1/payment_intents/pi_held/capture", _params}
    assert render(view) =~ "more than the payment holds"
    assert has_element?(view, "[data-payment-id=pi_held][data-status=authorized]")
  end

  test "Cancel lets the held money go and the row turns canceled", %{conn: conn} do
    StripeStub.stub(%{
      {"POST", "/v1/payment_intents/pi_held/cancel"} => intent("pi_held", "canceled"),
      {"GET", "/v1/payment_intents/pi_held"} => intent("pi_held", "canceled"),
      {"GET", "/v1/checkout/sessions"} => StripeStub.list([])
    })

    seed_payment("pi_held", :authorized)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("[data-payment-id=pi_held] [data-testid=capture-cancel]") |> render_click()

    assert_received {:stripe, "POST", "/v1/payment_intents/pi_held/cancel", _params}
    assert has_element?(view, "[data-payment-id=pi_held][data-status=canceled]")
  end

  # After the capture Stripe reads the payment as captured.
  defp stub_after_capture do
    StripeStub.stub(%{
      {"GET", "/v1/payment_intents/pi_held"} => fn _params ->
        intent("pi_held", "succeeded", 500)
      end,
      {"POST", "/v1/payment_intents/pi_held/capture"} => intent("pi_held", "succeeded", 500),
      {"GET", "/v1/checkout/sessions"} => StripeStub.list([])
    })
  end

  defp intent(id, status, captured \\ nil) do
    %{
      "object" => "payment_intent",
      "id" => id,
      "amount" => 1999,
      "amount_received" => captured || 0,
      "currency" => "usd",
      "status" => status,
      "capture_method" => "manual",
      "created" => 1_790_000_000,
      "metadata" => %{}
    }
  end

  defp seed_payment(id, status) do
    Ash.Seed.seed!(Shop.Pay.Payment, %{
      provider: "stripe",
      provider_id: id,
      tenant: "demo",
      status: status,
      amount: Decimal.new("19.99"),
      currency: "USD",
      synced_at: DateTime.utc_now()
    })
  end
end

defmodule ShopWeb.PaymentDetailsTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  test "the refund typed stays while a webhook updates the open payment, and is the one sent",
       %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/payment_intents/pi_paid"} => intent(),
      {"POST", "/v1/refunds"} => StripeRoutes.error(400, "Not in this test.")
    })

    payment =
      Ash.Seed.seed!(Shop.Pay.Payment, %{
        provider: "stripe",
        provider_id: "pi_paid",
        tenant: "demo",
        status: :paid,
        amount: Decimal.new("19.99"),
        currency: "USD",
        synced_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=payment-row][data-payment-id=pi_paid]") |> render_click()
    render_async(view)
    form = "[data-testid=refund-form]"

    view |> form(form, %{reason: "duplicate"}) |> render_change()
    view |> form(form, %{amount: "5.00"}) |> render_change()
    send(view.pid, {:mishka_pay, :payment, %{record: payment}})
    render_async(view)
    assert has_element?(view, "[data-testid=refund-reason] option[value=duplicate][selected]")

    view |> form(form) |> render_submit()

    assert_received {:stripe, "POST", "/v1/refunds",
                     %{"reason" => "duplicate", "amount" => "500"}}
  end

  defp intent do
    %{
      "object" => "payment_intent",
      "id" => "pi_paid",
      "amount" => 1999,
      "amount_received" => 1999,
      "currency" => "usd",
      "status" => "succeeded",
      "created" => 1_790_000_000,
      "metadata" => %{}
    }
  end
end

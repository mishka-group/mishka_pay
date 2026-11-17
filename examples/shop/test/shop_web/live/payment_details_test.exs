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

  test "a payment still waiting is canceled on Stripe and read back as canceled", %{conn: conn} do
    {:ok, status} = Agent.start_link(fn -> "requires_payment_method" end)
    read = fn _params -> intent("pi_open", Agent.get(status, & &1)) end

    StripeRoutes.stub(%{
      {"GET", "/v1/payment_intents/pi_paid"} => intent(),
      {"GET", "/v1/payment_intents/pi_open"} => read,
      {"POST", "/v1/payment_intents/pi_open/cancel"} => fn params ->
        Agent.update(status, fn _waiting -> "canceled" end)
        read.(params)
      end
    })

    seed("pi_open", :pending)
    seed("pi_paid", :paid)

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=payment-row][data-payment-id=pi_paid]") |> render_click()
    refute has_element?(view, "[data-testid=payment-cancel]")

    view |> element("[data-testid=payment-row][data-payment-id=pi_open]") |> render_click()
    assert view |> element("[data-testid=payment-cancel]") |> render() =~ "data-confirm"

    view |> element("[data-testid=payment-cancel]") |> render_click()
    render_async(view)

    assert_received {:stripe, "POST", "/v1/payment_intents/pi_open/cancel", _params}
    assert has_element?(view, "[data-testid=stored-status]", "canceled")
    assert has_element?(view, "[data-testid=live-status]", "canceled")
    refute has_element?(view, "[data-testid=payment-cancel]")
  end

  test "a cancel Stripe refuses says why and leaves the payment as it was", %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/payment_intents/pi_open"} => intent("pi_open", "processing"),
      {"POST", "/v1/payment_intents/pi_open/cancel"} =>
        StripeRoutes.error(400, "This PaymentIntent is processing and cannot be canceled.")
    })

    seed("pi_open", :pending)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=payment-row][data-payment-id=pi_open]") |> render_click()
    view |> element("[data-testid=payment-cancel]") |> render_click()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "[data-testid=stored-status]", "pending")
    assert has_element?(view, "[data-testid=payment-cancel]")
  end

  defp seed(provider_id, status) do
    Ash.Seed.seed!(Shop.Pay.Payment, %{
      provider: "stripe",
      provider_id: provider_id,
      tenant: "demo",
      status: status,
      amount: Decimal.new("19.99"),
      currency: "USD",
      synced_at: DateTime.utc_now()
    })
  end

  defp intent(id \\ "pi_paid", status \\ "succeeded") do
    %{
      "object" => "payment_intent",
      "id" => id,
      "amount" => 1999,
      "amount_received" => if(status == "succeeded", do: 1999, else: 0),
      "currency" => "usd",
      "status" => status,
      "created" => 1_790_000_000,
      "metadata" => %{}
    }
  end
end

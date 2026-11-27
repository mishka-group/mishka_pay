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

  test "a payment a checkout made has no Cancel, as only its checkout can end it", %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/payment_intents/pi_open"} => intent("pi_open", "requires_payment_method")
    })

    seed("pi_open", :pending, %{checkout_id: "cs_test_open"})
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=payment-row][data-payment-id=pi_open]") |> render_click()

    assert has_element?(view, "[data-testid=details-sync]")
    refute has_element?(view, "[data-testid=payment-cancel]")
  end

  test "a cancel of an intent an invoice made says to void the bill", %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/payment_intents/pi_open"} => intent("pi_open", "requires_payment_method"),
      {"POST", "/v1/payment_intents/pi_open/cancel"} =>
        StripeRoutes.error(
          400,
          "You cannot cancel PaymentIntents created by invoices. Try voiding the invoice instead."
        )
    })

    seed("pi_open", :pending)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=payment-row][data-payment-id=pi_open]") |> render_click()
    view |> element("[data-testid=payment-cancel]") |> render_click()

    assert has_element?(view, "#flash-error", "void the bill")
    refute has_element?(view, "#flash-error", "HTTP 400")
    assert has_element?(view, "[data-testid=stored-status]", "pending")
  end

  test "a payment shows Radar's risk, the review it holds and the checkout's metadata, live",
       %{conn: conn} do
    charge = %{
      "object" => "charge",
      "id" => "ch_risky",
      "outcome" => %{"risk_level" => "elevated", "risk_score" => 67},
      "review" => %{
        "object" => "review",
        "id" => "prv_risky",
        "open" => true,
        "reason" => "rule",
        "opened_reason" => "rule",
        "charge" => "ch_risky",
        "payment_intent" => "pi_paid"
      }
    }

    StripeRoutes.stub(%{
      {"GET", "/v1/payment_intents/pi_paid"} =>
        Map.merge(intent(), %{"latest_charge" => charge, "metadata" => %{"site" => "eu-shop"}})
    })

    seed("pi_paid", :paid)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=payment-row][data-payment-id=pi_paid]") |> render_click()
    render_async(view)

    assert has_element?(view, "[data-testid=live-risk]", "elevated, 67 of 99")
    assert has_element?(view, "[data-testid=live-fraud-review]", "prv_risky")
    assert has_element?(view, "[data-testid=live-fraud-review]", "open")
    assert has_element?(view, "[data-testid=live-metadata]", "eu-shop")
    assert has_element?(view, "[data-testid=live-disputed][data-disputed=false]")
  end

  test "the buy form's metadata goes on the checkout and on its PaymentIntent", %{conn: conn} do
    StripeRoutes.stub(%{
      {"POST", "/v1/checkout/sessions"} => %{
        "object" => "checkout.session",
        "id" => "cs_test_meta",
        "url" => "https://checkout.stripe.com/c/pay/cs_test_meta",
        "status" => "open"
      }
    })

    Ash.create!(
      Shop.Catalog.Product,
      %{slug: "hoodie", name: "Elixir hoodie", price: "39.00", interval: nil, position: 1},
      action: :seed,
      authorize?: false
    )

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#buy")
    |> render_submit(%{"product" => "hoodie", "meta_key" => "site", "meta_value" => "eu-shop"})

    assert_received {:stripe, "POST", "/v1/checkout/sessions", params}
    assert params["metadata"]["site"] == "eu-shop"
    assert params["payment_intent_data"]["metadata"]["site"] == "eu-shop"
  end

  test "a payment Radar has not scored says so and shows no review", %{conn: conn} do
    StripeRoutes.stub(%{{"GET", "/v1/payment_intents/pi_paid"} => intent()})

    seed("pi_paid", :paid)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=payment-row][data-payment-id=pi_paid]") |> render_click()
    render_async(view)

    assert has_element?(view, "[data-testid=live-risk]", "not scored")
    refute has_element?(view, "[data-testid=live-fraud-review]")
  end

  defp seed(provider_id, status, fields \\ %{}) do
    Ash.Seed.seed!(
      Shop.Pay.Payment,
      Map.merge(
        %{
          provider: "stripe",
          provider_id: provider_id,
          tenant: "demo",
          status: status,
          amount: Decimal.new("19.99"),
          currency: "USD",
          synced_at: DateTime.utc_now()
        },
        fields
      )
    )
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

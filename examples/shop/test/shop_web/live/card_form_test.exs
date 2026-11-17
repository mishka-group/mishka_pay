defmodule ShopWeb.CardFormTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  defp payment_intent(status, extra \\ %{}),
    do:
      Map.merge(
        %{
          "object" => "payment_intent",
          "id" => "pi_card_1",
          "amount" => 1200,
          "amount_received" => 0,
          "currency" => "usd",
          "capture_method" => "automatic",
          "status" => status,
          "client_secret" => "pi_card_1_secret_abc",
          "created" => 1_790_000_000
        },
        extra
      )

  defp setup_intent(status, extra \\ %{}),
    do:
      Map.merge(
        %{
          "object" => "setup_intent",
          "id" => "seti_card_1",
          "usage" => "off_session",
          "status" => status,
          "client_secret" => "seti_card_1_secret_abc",
          "created" => 1_790_000_000
        },
        extra
      )

  defp routes do
    %{
      {"POST", "/v1/payment_intents"} => payment_intent("requires_payment_method"),
      {"GET", "/v1/payment_intents/pi_card_1"} =>
        payment_intent("succeeded", %{"payment_method" => "pm_from_browser"}),
      {"POST", "/v1/payment_intents/pi_card_1/confirm"} => fn params ->
        case params["payment_method"] do
          "pm_card_chargeDeclined" ->
            {402,
             %{
               "error" => %{
                 "type" => "card_error",
                 "code" => "card_declined",
                 "decline_code" => "generic_decline",
                 "message" => "Your card was declined."
               }
             }}

          method ->
            payment_intent("succeeded", %{"payment_method" => method})
        end
      end,
      {"POST", "/v1/payment_intents/pi_card_1/cancel"} => payment_intent("canceled"),
      {"POST", "/v1/setup_intents"} => setup_intent("requires_payment_method"),
      {"POST", "/v1/setup_intents/seti_card_1/confirm"} => fn params ->
        setup_intent("succeeded", %{"payment_method" => params["payment_method"]})
      end
    }
  end

  defp opened(conn) do
    {:ok, view, _html} = live(conn, "/")
    view |> element("[data-testid=card-form-show]") |> render_click()
    view
  end

  test "nothing is asked of Stripe until a payment intent is made; Stripe's form mounts with its secret",
       %{conn: conn} do
    StripeRoutes.stub(routes())
    view = opened(conn)
    refute_received {:stripe, "POST", "/v1/payment_intents", _params}

    view
    |> form("[data-testid=card-payment-form]", %{amount: "12.00", currency: "usd", save: "true"})
    |> render_submit()

    assert_received {:stripe, "POST", "/v1/payment_intents", sent}

    assert %{
             "amount" => "1200",
             "currency" => "usd",
             "setup_future_usage" => "off_session",
             "automatic_payment_methods" => %{"enabled" => "true"}
           } = sent

    assert has_element?(
             view,
             ~s|[data-testid=card-payment-element][phx-hook][data-mode=payment][data-client-secret="pi_card_1_secret_abc"][data-publishable-key="pk_test_shop"]|
           )

    assert has_element?(view, "[data-testid=card-payment-status]", "requires_payment_method")

    view
    |> element("[data-testid=card-payment-element]")
    |> render_hook("stripe_confirmed", %{"mode" => "payment", "error" => nil})

    assert_received {:stripe, "GET", "/v1/payment_intents/pi_card_1", _params}
    assert has_element?(view, "[data-testid=card-payment-status]", "succeeded")
    assert has_element?(view, "[data-testid=card-payment-method]", "pm_from_browser")
    refute has_element?(view, "[data-testid=card-payment-element]")
  end

  test "a declined test card says so on a server confirm; another pays; a new one is canceled",
       %{conn: conn} do
    StripeRoutes.stub(routes())
    view = opened(conn)

    view |> form("[data-testid=card-payment-form]") |> render_submit()

    view
    |> form("[data-testid=card-payment-server-form]", %{payment_method: "pm_card_chargeDeclined"})
    |> render_submit()

    assert has_element?(view, "[data-testid=card-form-error]", "declined")
    assert has_element?(view, "[data-testid=card-payment-status]", "requires_payment_method")

    view
    |> form("[data-testid=card-payment-server-form]", %{payment_method: "pm_card_mastercard"})
    |> render_submit()

    assert_received {:stripe, "POST", "/v1/payment_intents/pi_card_1/confirm",
                     %{"payment_method" => "pm_card_mastercard", "return_url" => "http" <> _}}

    assert has_element?(view, "[data-testid=card-payment-status]", "succeeded")
    refute has_element?(view, "[data-testid=card-payment-cancel]")

    view |> form("[data-testid=card-payment-form]") |> render_submit()
    view |> element("[data-testid=card-payment-cancel]") |> render_click()

    assert_received {:stripe, "POST", "/v1/payment_intents/pi_card_1/cancel", _params}
    assert has_element?(view, "[data-testid=card-payment-status]", "canceled")
  end

  test "what is picked in a form stays picked while another part changes, and is what is sent",
       %{conn: conn} do
    StripeRoutes.stub(routes())
    view = opened(conn)
    pay = "[data-testid=card-payment-form]"
    save = "[data-testid=card-setup-form]"

    view |> form(pay, %{capture: "manual"}) |> render_change()
    view |> form(pay, %{amount: "15.00"}) |> render_change()
    view |> form(save, %{usage: "on_session"}) |> render_change()
    view |> form(save, %{customer_id: "cus_9"}) |> render_change()
    view |> form(save) |> render_submit()

    assert_received {:stripe, "POST", "/v1/setup_intents",
                     %{"customer" => "cus_9", "usage" => "on_session"}}

    server = "[data-testid=card-setup-server-form]"
    view |> form(server, %{payment_method: "pm_card_visa"}) |> render_change()
    assert has_element?(view, "[data-testid=card-payment-capture] option[value=manual][selected]")

    view |> form(pay) |> render_submit()

    assert_received {:stripe, "POST", "/v1/payment_intents",
                     %{"capture_method" => "manual", "amount" => "1500"}}

    view |> form(server) |> render_submit()

    assert_received {:stripe, "POST", "/v1/setup_intents/seti_card_1/confirm",
                     %{"payment_method" => "pm_card_visa"}}
  end

  test "a card is saved with a setup intent, confirmed on the server", %{conn: conn} do
    StripeRoutes.stub(routes())
    view = opened(conn)

    view
    |> form("[data-testid=card-setup-form]", %{customer_id: "cus_9", usage: "on_session"})
    |> render_submit()

    assert_received {:stripe, "POST", "/v1/setup_intents",
                     %{"customer" => "cus_9", "usage" => "on_session"}}

    assert has_element?(view, "[data-testid=card-setup-element][data-mode=setup]")

    view
    |> form("[data-testid=card-setup-server-form]", %{payment_method: "pm_card_visa"})
    |> render_submit()

    assert has_element?(view, "[data-testid=card-setup-status]", "succeeded")
    assert has_element?(view, "[data-testid=card-setup-method]", "pm_card_visa")
  end

  test "an amount that cannot be right, or no publishable key, says so and makes nothing",
       %{conn: conn} do
    StripeRoutes.stub(routes())
    view = opened(conn)

    view
    |> form("[data-testid=card-payment-form]", %{amount: "-3"})
    |> render_submit()

    assert has_element?(view, "[data-testid=card-form-error]")
    assert has_element?(view, "[data-testid=card-payment-amount][value='-3']")

    StripeRoutes.stub(routes(), %{publishable_key: nil})
    view |> form("[data-testid=card-setup-form]") |> render_submit()

    assert has_element?(view, "[data-testid=card-form-error]", "STRIPE_PUBLISHABLE_KEY")
    refute_received {:stripe, "POST", _path, _params}
  end
end

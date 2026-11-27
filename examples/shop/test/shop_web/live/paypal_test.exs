defmodule ShopWeb.PayPalTest do
  use ShopWeb.ConnCase, async: false

  # The refused webhooks log a warning each.
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias MishkaPay.Test.PayPal
  alias Shop.Pay.WebhookSimulator
  alias ShopWeb.StripeRoutes

  setup do
    MishkaPay.Test.put_keys(
      "paypal",
      %{publishable_key: "client_d", secret_key: "secret_d", webhook_secret: "WH-D", mode: :test},
      "demo"
    )

    StripeRoutes.stub(%{})
    PayPal.stub!()

    # PayPal's stand-in answers PayPal; the page's Stripe lists are empty.
    MishkaPay.Test.stub_http(fn
      %{host: "api-m.sandbox.paypal.com"} = conn -> PayPal.forward(conn)
      conn -> Req.Test.json(conn, StripeRoutes.list([]))
    end)

    :ok
  end

  test "a PayPal checkout sends the seller's own tax on its line, added on top or held in the price",
       %{conn: conn} do
    Ash.create!(
      Shop.Catalog.Product,
      %{slug: "ebook", name: "Elixir ebook", price: "39.00", interval: nil, position: 1},
      action: :seed,
      authorize?: false
    )

    for {inclusive, unit, tax} <- [{nil, "39.00", "7.41"}, {"true", "32.77", "6.23"}] do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "[data-testid=option-tax-percentage]")

      buy = %{"product" => "ebook", "provider" => "paypal", "tax_percentage" => "19"}
      buy = if inclusive, do: Map.put(buy, "tax_inclusive", inclusive), else: buy

      assert {:error, {:redirect, %{to: "https://www.sandbox.paypal.com/" <> _approve}}} =
               view |> form("#buy") |> render_submit(buy)

      assert_received {:paypal, "POST", "/v2/checkout/orders", _headers, order}
      [%{"items" => [item], "amount" => amount}] = order["purchase_units"]
      assert item["unit_amount"]["value"] == unit
      assert item["tax"]["value"] == tax
      assert amount["breakdown"]["tax_total"]["value"] == tax
    end
  end

  test "a PayPal payment the buyer disputed shows as disputed, live from PayPal", %{conn: conn} do
    PayPal.order("ORDERDISP1", "COMPLETED",
      captures: [%{"id" => "CAPTUREORDERDISP1", "status" => "COMPLETED"}]
    )

    PayPal.dispute("ORDERDISP1", "PP-D-1", "OPEN")

    Ash.Seed.seed!(Shop.Pay.Payment, %{
      provider: "paypal",
      provider_id: "ORDERDISP1",
      tenant: "demo",
      status: :paid,
      amount: Decimal.new("19.99"),
      currency: "USD",
      synced_at: DateTime.utc_now()
    })

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=payment-row][data-payment-id=ORDERDISP1]") |> render_click()
    render_async(view)

    assert has_element?(view, "[data-testid=live-disputed][data-disputed=true]")
    refute has_element?(view, "[data-testid=live-risk]")
  end

  for {situation, reason} <- [paypal_too_old: "too_old", paypal_certificate: "certificate"] do
    test "the simulator's #{situation} is refused with 400 before PayPal is asked, and counted",
         %{conn: conn} do
      %{body: body, headers: headers} =
        WebhookSimulator.paypal_request("SIMORDER1", "demo", unquote(situation))

      conn =
        Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

      assert conn |> post("/pay/webhooks/paypal/demo", body) |> response(400)

      refute_received {:paypal, _method, _path, _headers, _body}

      assert [%{reason: unquote(reason), provider: "paypal", count: 1}] =
               Ash.read!(Shop.Pay.WebhookRejection, authorize?: false)
    end
  end

  test "the simulator's PayPal part waits for the site's PayPal webhook id", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "[data-testid=simulate-paypal-form]")

    MishkaPay.Test.put_keys(
      "paypal",
      %{publishable_key: "client_d", secret_key: "secret_d", mode: :test},
      "demo"
    )

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "[data-testid=simulate-paypal-off]")
    refute has_element?(view, "[data-testid=simulate-paypal-form]")
  end
end

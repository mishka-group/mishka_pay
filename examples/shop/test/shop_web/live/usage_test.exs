defmodule ShopWeb.UsageTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  defp meter(status) do
    %{
      "id" => "mtr_1",
      "object" => "billing.meter",
      "display_name" => "API calls",
      "event_name" => "api_call",
      "default_aggregation" => %{"formula" => "sum"},
      "status" => status
    }
  end

  setup do
    test = self()

    StripeStub.stub(fn
      "POST", "/v1/billing/meters", %{"event_name" => "api_call"} ->
        Process.put(:meter, "active")
        meter("active")

      "GET", "/v1/billing/meters", _params ->
        StripeStub.list(List.wrap(Process.get(:meter) && meter(Process.get(:meter))))

      "POST", "/v1/billing/meters/mtr_1/deactivate", _params ->
        Process.put(:meter, "inactive")
        meter("inactive")

      "POST", "/v1/billing/meter_events", %{"payload" => payload} = params ->
        send(test, {:reported, payload})
        %{"identifier" => params["identifier"], "event_name" => "api_call"}

      "GET", "/v1/billing/meters/mtr_1/event_summaries", %{"customer" => "cus_1"} ->
        StripeStub.list([
          %{"aggregated_value" => 7, "start_time" => 1_790_000_000, "end_time" => 1_790_003_600}
        ])

      "POST", "/v1/prices", %{"recurring" => %{"meter" => "mtr_1", "usage_type" => "metered"}} ->
        %{
          "id" => "price_m1",
          "product" => "prod_1",
          "unit_amount" => 5,
          "currency" => "usd",
          "active" => true,
          "recurring" => %{"interval" => "month", "interval_count" => 1, "meter" => "mtr_1"}
        }

      _method, _path, _params ->
        nil
    end)

    :ok
  end

  test "makes a meter, lists it and turns it off", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> form("[data-testid=meter-form]", %{
      name: "API calls",
      event_name: "api_call",
      aggregation: "sum"
    })
    |> render_submit()

    assert has_element?(view, "[data-testid=usage-notice]", "mtr_1")
    assert has_element?(view, "[data-meter-id=mtr_1] [data-testid=meter-status]", "active")

    view |> element("[data-meter-id=mtr_1] [data-testid=meter-deactivate]") |> render_click()
    assert has_element?(view, "[data-meter-id=mtr_1] [data-testid=meter-status]", "inactive")
    refute has_element?(view, "[data-meter-id=mtr_1] [data-testid=meter-deactivate]")
  end

  test "reports usage, reads the summary, and makes a metered price", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> form("[data-testid=usage-report-form]", %{
      event_name: "api_call",
      customer_id: "cus_1",
      value: "3",
      reference: "use-1"
    })
    |> render_submit()

    assert_received {:reported, %{"stripe_customer_id" => "cus_1", "value" => "3"}}
    assert has_element?(view, "[data-testid=usage-reported]", "cus_1")

    view
    |> form("[data-testid=usage-summary-form]", %{
      meter_id: "mtr_1",
      customer_id: "cus_1",
      window: "day"
    })
    |> render_submit()

    assert has_element?(view, "[data-testid=usage-summary-value]", "7")

    view
    |> form("[data-testid=metered-price-form]", %{
      product_id: "prod_1",
      meter_id: "mtr_1",
      amount: "0.05",
      currency: "USD",
      interval: "month"
    })
    |> render_submit()

    assert has_element?(view, "[data-testid=metered-price]", "price_m1")
  end

  test "says what is wrong with a usage report", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> form("[data-testid=usage-report-form]", %{
      event_name: "api_call",
      customer_id: "cus_1",
      value: "1.5.2",
      reference: "use-2"
    })
    |> render_submit()

    assert has_element?(view, "[data-testid=usage-error]")
    refute_received {:reported, _payload}
  end
end

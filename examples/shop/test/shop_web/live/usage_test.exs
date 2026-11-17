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

      "POST", "/v1/billing/meters/mtr_1/reactivate", _params ->
        Process.put(:meter, "active")
        meter("active")

      "POST", "/v1/billing/meter_event_adjustments", %{"cancel" => cancel} = params ->
        send(test, {:cancelled, params["event_name"], cancel["identifier"]})

        %{
          "object" => "billing.meter_event_adjustment",
          "event_name" => params["event_name"],
          "cancel" => cancel,
          "status" => "pending",
          "type" => "cancel"
        }

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

    view |> element("[data-meter-id=mtr_1] [data-testid=meter-reactivate]") |> render_click()
    assert has_element?(view, "[data-meter-id=mtr_1] [data-testid=meter-status]", "active")
    assert has_element?(view, "[data-testid=usage-notice]", "on again")
    refute has_element?(view, "[data-meter-id=mtr_1] [data-testid=meter-reactivate]")
  end

  test "a report sent by mistake is taken back once", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, "[data-testid=usage-cancel]")

    view
    |> form("[data-testid=usage-report-form]", %{
      event_name: "api_call",
      customer_id: "cus_1",
      value: "9",
      reference: "use-oops"
    })
    |> render_submit()

    assert_received {:reported, %{"value" => "9"}}
    view |> element("[data-testid=usage-cancel]") |> render_click()

    assert_received {:cancelled, "api_call", "mishka_pay-usage-" <> _}
    assert has_element?(view, "[data-testid=usage-cancel-status]", "pending")
    refute has_element?(view, "[data-testid=usage-cancel]")
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

  test "each form's select keeps what was picked while the others change the page",
       %{conn: conn} do
    test = self()

    StripeStub.stub(fn
      "POST", "/v1/billing/meters", params ->
        send(test, {:meter, params})
        meter("active")

      "GET", "/v1/billing/meters/mtr_1/event_summaries", params ->
        send(test, {:summary, String.to_integer(params["start_time"])})
        StripeStub.list([])

      "POST", "/v1/prices", params ->
        send(test, {:price, params})
        nil

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")
    meter_form = "[data-testid=meter-form]"
    summary = "[data-testid=usage-summary-form]"
    price = "[data-testid=metered-price-form]"

    view |> form(meter_form, %{aggregation: "count"}) |> render_change()
    view |> form(meter_form, %{name: "API calls", event_name: "api_call"}) |> render_change()
    view |> form(summary, %{window: "month"}) |> render_change()
    view |> form(price, %{currency: "EUR"}) |> render_change()
    view |> form(price, %{interval: "year"}) |> render_change()
    view |> element("[data-testid=meters-list]") |> render_click()
    assert has_element?(view, "[data-testid=metered-interval] option[value=year][selected]")

    view |> form(meter_form) |> render_submit()

    assert_received {:meter,
                     %{
                       "event_name" => "api_call",
                       "default_aggregation" => %{"formula" => "count"}
                     }}

    view |> form(summary, %{meter_id: "mtr_1", customer_id: "cus_1"}) |> render_submit()
    assert_received {:summary, from}
    assert from <= System.os_time(:second) - 29 * 86_400

    view |> form(price, %{product_id: "prod_1", meter_id: "mtr_1"}) |> render_submit()

    assert_received {:price, %{"currency" => "eur", "recurring" => %{"interval" => "year"}}}
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

    assert has_element?(view, "[data-testid=usage-report-error]")
    assert has_element?(view, "[data-testid=usage-value][value='1.5.2']")
    refute_received {:reported, _payload}
  end

  test "a reference already used says why and keeps what was typed", %{conn: conn} do
    StripeStub.stub(fn
      "POST", "/v1/billing/meter_events", _params ->
        StripeStub.error(
          "An event already exists with identifier use-taken.",
          "meter_event_identifier_already_exists"
        )

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")
    report = "[data-testid=usage-report-form]"

    typed = %{event_name: "api_call", customer_id: "cus_1", value: "4", reference: "use-taken"}
    view |> form(report, typed) |> render_change()
    view |> form(report, typed) |> render_submit()

    assert has_element?(view, "[data-testid=usage-report-error]", "already_exists")
    refute has_element?(view, "[data-testid=usage-reported]")
    assert has_element?(view, "[data-testid=usage-event][value=api_call]")
    assert has_element?(view, "[data-testid=usage-customer][value=cus_1]")
    assert has_element?(view, "[data-testid=usage-value][value='4']")
    assert has_element?(view, "[data-testid=usage-reference][value=use-taken]")

    view |> form(report, %{typed | reference: "use-new"}) |> render_change()
    refute has_element?(view, "[data-testid=usage-report-error]")
  end
end

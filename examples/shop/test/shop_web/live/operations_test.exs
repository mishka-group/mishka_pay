defmodule ShopWeb.OperationsTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  @url "https://shop.test/pay/webhooks/stripe/demo"

  defp event(id, type),
    do: %{
      "id" => id,
      "object" => "event",
      "type" => type,
      "created" => System.system_time(:second) - 60,
      "livemode" => false,
      "data" => %{"object" => %{"object" => "product", "id" => "prod_1"}}
    }

  test "runs every check and shows each one's reason", %{conn: conn} do
    StripeStub.stub(fn _method, _path, _params -> nil end)
    {:ok, view, _html} = live(conn, "/")

    view
    |> form("[data-testid=operations-setup-form]", %{url: @url})
    |> render_submit(%{intent: "checks"})

    assert has_element?(view, "[data-testid=check-row][data-check=provider][data-ok=true]")
    assert has_element?(view, "[data-testid=check-row][data-check=keys][data-ok=true]")

    assert has_element?(
             view,
             "[data-testid=check-row][data-check=webhook_endpoint][data-ok=false] [data-testid=check-reason]",
             "no webhook endpoint at #{@url}"
           )
  end

  test "checks the endpoint at a URL and makes one only on a click", %{conn: conn} do
    test = self()

    StripeStub.stub(fn
      "GET", "/v1/webhook_endpoints", _params ->
        StripeStub.list(List.wrap(Process.get(:endpoint)))

      "POST", "/v1/webhook_endpoints", %{"url" => @url} = params ->
        send(test, :made)

        endpoint =
          %{
            "id" => "we_1",
            "url" => @url,
            "status" => "enabled",
            "enabled_events" => params["enabled_events"] |> Map.values(),
            "api_version" => params["api_version"]
          }

        Process.put(:endpoint, endpoint)
        Map.put(endpoint, "secret", "whsec_made_once")

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("[data-testid=operations-setup-form]", %{url: @url})
    |> render_submit(%{intent: "endpoint"})

    assert has_element?(view, "[data-testid=endpoint-none]")
    refute_received :made

    html =
      view
      |> form("[data-testid=operations-setup-form]", %{url: @url})
      |> render_submit(%{intent: "ensure"})

    assert_received :made
    assert has_element?(view, "[data-testid=endpoint-id]", "we_1")
    assert has_element?(view, "[data-testid=endpoint-complete]")
    refute html =~ "whsec_made_once"

    view
    |> form("[data-testid=operations-setup-form]", %{url: @url})
    |> render_submit(%{intent: "endpoint"})

    assert has_element?(view, "[data-testid=endpoint-status]", "enabled")
  end

  test "lists the last hour's events and delivers them again", %{conn: conn} do
    StripeStub.stub(fn
      "GET", "/v1/events", %{"created" => %{"gte" => _since}} ->
        StripeStub.list([event("evt_1", "product.updated")])

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")

    view |> element("[data-testid=operations-events]") |> render_click()
    assert has_element?(view, "[data-testid=event-row][data-event-id=evt_1]", "product.updated")

    view
    |> form("[data-testid=operations-replay-form]", %{window: "1h"})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "[data-testid=replay-delivered]", "1")
    assert has_element?(view, "[data-testid=replay-failed]", "0")

    # A window the form does not offer falls back to an hour instead of stopping the page.
    view
    |> element("[data-testid=operations-replay-form]")
    |> render_submit(%{"window" => "hour"})

    render_async(view)
    assert has_element?(view, "[data-testid=replay-delivered]", "1")
  end

  test "the replay window picked stays picked while the events are read, and is the one used",
       %{conn: conn} do
    test = self()

    StripeStub.stub(fn
      "GET", "/v1/events", %{"created" => %{"gte" => since}} ->
        send(test, {:since, String.to_integer(since)})
        StripeStub.list([])

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")
    form = "[data-testid=operations-replay-form]"

    view |> form(form, %{window: "1d"}) |> render_change()
    view |> element("[data-testid=operations-events]") |> render_click()
    assert_received {:since, _hour_ago}

    assert has_element?(
             view,
             "[data-testid=operations-replay-window] option[value='1d'][selected]"
           )

    view |> form(form) |> render_submit()
    render_async(view)

    assert_received {:since, since}
    assert since <= System.os_time(:second) - 86_000
  end

  test "compares the pinned Stripe API version with the newest", %{conn: conn} do
    StripeStub.stub(fn
      "GET", "/stripe/openapi/master/latest/openapi.spec3.json", _params ->
        %{"openapi" => "3.0.0", "info" => %{"version" => "2099-01-01.zebra"}}

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")
    view |> element("[data-testid=operations-version]") |> render_click()

    assert has_element?(
             view,
             "[data-testid=version-pinned]",
             MishkaPay.Providers.Stripe.version()
           )

    assert has_element?(view, "[data-testid=version-latest]", "2099-01-01.zebra")
    assert has_element?(view, "[data-testid=version-current]", "no")
  end
end

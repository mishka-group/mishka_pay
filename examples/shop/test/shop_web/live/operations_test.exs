defmodule ShopWeb.OperationsTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  @url "https://shop.test/pay/webhooks/stripe/demo"

  # A thin event as API v2's event list answers it, about a product (named by its own id, so
  # nothing is read for it).
  defp event(id, type),
    do: %{
      "id" => id,
      "object" => "v2.core.event",
      "type" => type,
      "created" => DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601(),
      "livemode" => false,
      "context" => nil,
      "related_object" => %{"id" => "prod_1", "type" => "product", "url" => "/v1/products/prod_1"}
    }

  defp v2_list(data), do: %{"data" => data, "next_page_url" => nil}

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

  test "the site takes thin events by default, and makes a thin event destination only on a click",
       %{conn: conn} do
    test = self()

    StripeStub.stub(fn
      "GET", "/v2/core/event_destinations", _params ->
        v2_list(List.wrap(Process.get(:destination)))

      "POST", "/v2/core/event_destinations", %{"webhook_endpoint" => %{"url" => @url}} = params ->
        send(test, {:made, params})

        destination = %{
          "id" => "ed_test_1",
          "object" => "v2.core.event_destination",
          "event_payload" => params["event_payload"],
          "events_from" => params["events_from"],
          "status" => "enabled",
          "enabled_events" => params["enabled_events"],
          "webhook_endpoint" => %{"url" => @url, "signing_secret" => nil}
        }

        Process.put(:destination, destination)
        put_in(destination, ["webhook_endpoint", "signing_secret"], "whsec_made_once")

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "[data-testid=operations-site-kind][data-kind=thin]")
    assert has_element?(view, "[data-testid=operations-kind] option[value=thin][selected]")

    view
    |> form("[data-testid=operations-setup-form]", %{url: @url})
    |> render_submit(%{intent: "endpoint"})

    assert has_element?(view, "[data-testid=endpoint-none]")
    refute_received {:made, _params}

    html =
      view
      |> form("[data-testid=operations-setup-form]", %{url: @url})
      |> render_submit(%{intent: "ensure"})

    assert_received {:made, %{"event_payload" => "thin", "type" => "webhook_endpoint"}}
    assert has_element?(view, "[data-testid=endpoint-id]", "ed_test_1")
    assert has_element?(view, "[data-testid=endpoint-events]", "thin")
    assert has_element?(view, "[data-testid=endpoint-complete]")
    refute html =~ "whsec_made_once"

    view
    |> form("[data-testid=operations-setup-form]", %{url: @url})
    |> render_submit(%{intent: "endpoint"})

    assert has_element?(view, "[data-testid=endpoint-status]", "enabled")
    assert has_element?(view, "[data-testid=endpoint-from]", "@self")
  end

  test "an older v1 snapshot endpoint is checked and made when that kind is picked",
       %{conn: conn} do
    test = self()

    StripeStub.stub(fn
      "GET", "/v1/webhook_endpoints", _params ->
        StripeStub.list([])

      "POST", "/v1/webhook_endpoints", %{"url" => @url} = params ->
        send(test, :made)

        %{
          "id" => "we_1",
          "url" => @url,
          "status" => "enabled",
          "enabled_events" => Map.values(params["enabled_events"]),
          "api_version" => params["api_version"]
        }

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")
    setup = %{url: @url, kind: "snapshot_v1"}

    view
    |> form("[data-testid=operations-setup-form]", setup)
    |> render_submit(%{intent: "endpoint"})

    assert has_element?(view, "[data-testid=endpoint-none]")

    view
    |> form("[data-testid=operations-setup-form]", setup)
    |> render_submit(%{intent: "ensure"})

    assert_received :made
    assert has_element?(view, "[data-testid=endpoint-id]", "we_1")
    assert has_element?(view, "[data-testid=endpoint-api]", "v1")
    assert has_element?(view, "[data-testid=operations-kind] option[value=snapshot_v1][selected]")
  end

  test "lists the last hour's thin events and delivers them again", %{conn: conn} do
    StripeStub.stub(fn
      "GET", "/v2/core/events", %{"created" => %{"gte" => _since}} ->
        v2_list([event("evt_test_1", "v1.product.updated")])

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")

    view |> element("[data-testid=operations-events]") |> render_click()

    assert has_element?(
             view,
             "[data-testid=event-row][data-event-id=evt_test_1]",
             "product.updated"
           )

    refute has_element?(view, "[data-testid=event-row]", "v1.product.updated")

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
      "GET", "/v2/core/events", %{"created" => %{"gte" => since}} ->
        {:ok, at, 0} = DateTime.from_iso8601(since)
        send(test, {:since, DateTime.to_unix(at)})
        v2_list([])

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

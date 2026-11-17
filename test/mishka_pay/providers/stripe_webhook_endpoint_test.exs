# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.StripeWebhookEndpointTest do
  # Starts the Stripe plugin, which changes the providers event every test sees.
  use ExUnit.Case, async: false

  alias MishkaPay.Errors.Invalid
  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Providers.Stripe.WebhookEndpoint

  @url "https://shop.test/pay/webhooks/stripe/site-a"

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_a"}, "site-a")
    :ok
  end

  # Stripe with the destinations (API v2) and v1 endpoints given; stripe-mock knows no API v2, so
  # this stand-in answers in Stripe's own shapes and tells the test each request and its body.
  defp stripe(destinations, endpoints \\ []) do
    test_pid = self()

    MishkaPay.Test.stub_http(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      sent = read(conn, body)
      send(test_pid, {conn.method, conn.request_path, sent})
      answer(conn, sent, destinations, endpoints)
    end)
  end

  defp read(%{method: "GET"} = conn, _body), do: URI.decode_query(conn.query_string)
  defp read(_conn, "{" <> _ = json), do: JSON.decode!(json)
  defp read(_conn, form), do: form |> URI.query_decoder() |> Enum.to_list()

  defp answer(%{method: "GET", request_path: "/v2/" <> _} = conn, _sent, destinations, _),
    do: Req.Test.json(conn, %{"data" => destinations, "next_page_url" => nil})

  defp answer(%{method: "GET"} = conn, _sent, _destinations, endpoints),
    do: Req.Test.json(conn, %{"data" => endpoints, "has_more" => false})

  defp answer(%{method: "DELETE"} = conn, _sent, _destinations, _endpoints),
    do: Req.Test.json(conn, %{})

  defp answer(%{request_path: "/v2/core/event_destinations" <> rest} = conn, sent, _, _) do
    kept = Map.take(sent, ~w(event_payload events_from enabled_events snapshot_api_version))
    answered = destination([], Map.merge(kept, changed(rest)))
    Req.Test.json(conn, answered)
  end

  defp answer(%{request_path: "/v1/webhook_endpoints" <> rest} = conn, form, _, _) do
    status =
      (List.keyfind(form, "disabled", 0) == {"disabled", "true"} && "disabled") || "enabled"

    Req.Test.json(conn, %{
      "id" => "we_1",
      "object" => "webhook_endpoint",
      "url" => @url,
      "status" => status,
      "enabled_events" => for({"enabled_events[" <> _, event} <- form, do: event),
      "secret" => (rest == "" && "whsec_new") || nil
    })
  end

  # A new destination answers its signing secret once; a disabled one its status.
  defp changed(""),
    do: %{
      "id" => "ed_test_new",
      "webhook_endpoint" => %{"url" => @url, "signing_secret" => "whsec_new"}
    }

  defp changed("/ed_test_1/disable"), do: %{"status" => "disabled"}
  defp changed(_other), do: %{}

  defp destination(events, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "ed_test_1",
        "object" => "v2.core.event_destination",
        "event_payload" => "thin",
        "events_from" => ["@self"],
        "enabled_events" => events,
        "status" => "enabled",
        "webhook_endpoint" => %{"url" => @url, "signing_secret" => nil}
      },
      overrides
    )
  end

  defp thin, do: Stripe.thin_events() |> Map.keys() |> Enum.sort()
  defp snapshot, do: Stripe.handled_events() |> Map.keys() |> Enum.sort()

  test "a site without one gets a thin event destination with every thin event, asking for its secret" do
    stripe([destination(["*"], %{"event_payload" => "snapshot"})])

    assert {:ok,
            %WebhookEndpoint{
              id: "ed_test_new",
              api: :v2,
              events: :thin,
              secret: "whsec_new",
              url: @url,
              enabled_events: events
            }} = WebhookEndpoint.ensure("site-a", @url)

    assert Enum.sort(events) == thin()

    assert_received {"GET", "/v2/core/event_destinations",
                     %{"include[0]" => "webhook_endpoint.url"}}

    assert_received {"POST", "/v2/core/event_destinations", sent}

    assert %{
             "type" => "webhook_endpoint",
             "event_payload" => "thin",
             "events_from" => ["@self"],
             "webhook_endpoint" => %{"url" => @url}
           } = sent

    assert "webhook_endpoint.signing_secret" in sent["include"]
    refute Map.has_key?(sent, "snapshot_api_version")
    assert "v1.billing.meter.error_report_triggered" in sent["enabled_events"]
    assert "v1.customer.subscription.past_due" in sent["enabled_events"]
  end

  test "a platform's destination takes its connected accounts' events too" do
    stripe([])

    assert {:ok, %WebhookEndpoint{events_from: ["@self", "@accounts"]}} =
             WebhookEndpoint.ensure("site-a", @url, connected_accounts: true)

    assert_received {"POST", "/v2/core/event_destinations",
                     %{"events_from" => ["@self", "@accounts"]}}
  end

  test "snapshot events on a destination are rendered in the pinned API version" do
    stripe([destination(["v1.invoice.paid"])])

    assert {:ok, %WebhookEndpoint{events: :snapshot, api_version: version}} =
             WebhookEndpoint.ensure("site-a", @url, events: :snapshot)

    assert version == Stripe.version()
    assert_received {"POST", "/v2/core/event_destinations", sent}
    assert %{"event_payload" => "snapshot", "snapshot_api_version" => ^version} = sent
    assert Enum.sort(sent["enabled_events"]) == snapshot()
  end

  test "the site's keys pick the kind, and a call's own option wins" do
    MishkaPay.Test.put_keys(
      "stripe",
      %{secret_key: "sk_test_a", events: :snapshot, webhook_api: :v1},
      "site-a"
    )

    stripe([], [])
    assert {:ok, %{endpoint: nil, missing: missing}} = WebhookEndpoint.check("site-a", @url)
    assert missing == snapshot()
    assert_received {"GET", "/v1/webhook_endpoints", _query}

    assert {:ok, %{missing: missing}} =
             WebhookEndpoint.check("site-a", @url, events: :thin, api: :v2)

    assert missing == thin()
    assert_received {"GET", "/v2/core/event_destinations", _query}
  end

  test "a destination missing thin events gets them added, keeping its own" do
    stripe([destination(["v1.invoice.paid", "v1.issuing_card.created"])])

    assert {:ok, %{missing: missing}} = WebhookEndpoint.check("site-a", @url)
    assert missing == thin() -- ["v1.invoice.paid"]
    refute_received {"POST", _path, _sent}

    assert {:ok, %WebhookEndpoint{id: "ed_test_1", secret: nil, enabled_events: events}} =
             WebhookEndpoint.ensure("site-a", @url)

    assert "v1.issuing_card.created" in events
    assert Enum.all?(thin(), &(&1 in events))

    assert_received {"POST", "/v2/core/event_destinations/ed_test_1",
                     %{"include" => ["webhook_endpoint.url"]}}
  end

  test "a destination with every event, or all of them, is left as it is" do
    for events <- [["*"], thin()] do
      stripe([destination(events)])
      assert {:ok, %{missing: []}} = WebhookEndpoint.check("site-a", @url)
      assert {:ok, %WebhookEndpoint{id: "ed_test_1"}} = WebhookEndpoint.ensure("site-a", @url)
      refute_received {"POST", _path, _sent}
    end
  end

  test "a v1 endpoint Stripe lists among its destinations is changed on its own API" do
    stripe([
      destination(["invoice.paid"], %{"id" => "we_1", "event_payload" => "snapshot"})
    ])

    assert {:ok, %WebhookEndpoint{id: "we_1", api: :v1}} =
             WebhookEndpoint.ensure("site-a", @url, events: :snapshot)

    assert_received {"POST", "/v1/webhook_endpoints/we_1", form}
    assert {"enabled_events[0]", _event} = List.keyfind(form, "enabled_events[0]", 0)
  end

  describe "the older v1 endpoints" do
    test "a site without one gets one with every snapshot event, on the pinned version" do
      stripe([], [
        %{"id" => "we_other", "url" => "https://elsewhere.test", "enabled_events" => ["*"]}
      ])

      assert {:ok,
              %WebhookEndpoint{id: "we_1", api: :v1, secret: "whsec_new", enabled_events: events}} =
               WebhookEndpoint.ensure("site-a", @url, api: :v1, events: :snapshot)

      assert Enum.sort(events) == snapshot()
      assert_received {"POST", "/v1/webhook_endpoints", form}
      assert {"api_version", Stripe.version()} in form
      assert {"url", @url} in form
      refute List.keymember?(form, "connect", 0)
    end

    test "an endpoint missing events gets them added, keeping its own" do
      stripe([], [
        %{
          "id" => "we_1",
          "url" => @url,
          "enabled_events" => ["invoice.paid", "issuing_card.created"]
        }
      ])

      assert {:ok, %{missing: missing}} =
               WebhookEndpoint.check("site-a", @url, api: :v1, events: :snapshot)

      assert missing == snapshot() -- ["invoice.paid"]

      assert {:ok, %WebhookEndpoint{enabled_events: events}} =
               WebhookEndpoint.ensure("site-a", @url, api: "v1", events: "snapshot")

      assert "issuing_card.created" in events
      assert_received {"POST", "/v1/webhook_endpoints/we_1", _form}
    end

    test "thin events on a v1 endpoint are refused before any request" do
      MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)

      assert {:error, %Invalid{errors: [%{field: :api}]}} =
               WebhookEndpoint.ensure("site-a", @url, api: :v1)

      assert {:error, %Invalid{errors: [%{field: :events}]}} =
               WebhookEndpoint.check("site-a", @url, events: :fat)
    end
  end

  test "an endpoint is turned off, on and deleted on the API its id belongs to" do
    stripe([])

    assert {:ok, %WebhookEndpoint{status: :disabled}} =
             WebhookEndpoint.disable("site-a", "ed_test_1")

    assert_received {"POST", "/v2/core/event_destinations/ed_test_1/disable", _sent}

    assert {:ok, %WebhookEndpoint{status: :enabled}} =
             WebhookEndpoint.enable("site-a", "ed_test_1")

    assert_received {"POST", "/v2/core/event_destinations/ed_test_1/enable", _sent}

    assert {:ok, %WebhookEndpoint{api: :v1}} = WebhookEndpoint.disable("site-a", "we_1")
    assert_received {"POST", "/v1/webhook_endpoints/we_1", [{"disabled", "true"}]}

    assert :ok = WebhookEndpoint.delete("site-a", "ed_test_1")
    assert_received {"DELETE", "/v2/core/event_destinations/ed_test_1", _query}

    assert :ok = WebhookEndpoint.delete("site-a", "we_1")
    assert_received {"DELETE", "/v1/webhook_endpoints/we_1", _query}
  end

  test "an address that is not an https URL, or an id that is not an endpoint's, is refused before any request" do
    MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)

    for url <- ["not a url", "ftp://shop.test/x", "http://shop.test/pay", ""] do
      assert {:error, %Invalid{errors: [%{field: :url}]}} = WebhookEndpoint.check("site-a", url)
      assert {:error, %Invalid{}} = WebhookEndpoint.ensure("site-a", url)
    end

    for id <- ["../v1/charges", "ed_../x", "we_1/../../v1/charges", "evt_1"] do
      assert {:error, %Invalid{errors: [%{field: :endpoint_id}]}} =
               WebhookEndpoint.delete("site-a", id)

      assert {:error, %Invalid{}} = WebhookEndpoint.disable("site-a", id)
    end
  end
end

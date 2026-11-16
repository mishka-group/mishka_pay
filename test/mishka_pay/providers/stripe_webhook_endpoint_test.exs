# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.StripeWebhookEndpointTest do
  # Starts the Stripe plugin, which changes the providers event every test sees.
  use ExUnit.Case, async: false

  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Providers.Stripe.WebhookEndpoint

  @url "https://shop.test/pay/webhooks/stripe/site-a"

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_a"}, "site-a")
    :ok
  end

  # Stripe with the endpoints given; it tells the test each write and its form.
  defp stripe(endpoints) do
    test_pid = self()

    MishkaPay.Test.stub_http(fn conn ->
      case conn.method do
        "GET" -> Req.Test.json(conn, %{"data" => endpoints, "has_more" => false})
        "POST" -> written(conn, test_pid)
      end
    end)
  end

  defp written(conn, test_pid) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    form = body |> URI.query_decoder() |> Enum.to_list()
    send(test_pid, {:write, conn.request_path, form})
    events = for {"enabled_events[" <> _, event} <- form, do: event

    Req.Test.json(conn, %{
      "id" => "we_1",
      "url" => @url,
      "status" => "enabled",
      "enabled_events" => events,
      "secret" => (conn.request_path == "/v1/webhook_endpoints" && "whsec_new") || nil
    })
  end

  defp handled, do: Stripe.handled_events() |> Map.keys() |> Enum.sort()

  test "a site without an endpoint gets one with every handled event, on the pinned version" do
    stripe([%{"id" => "we_other", "url" => "https://elsewhere.test", "enabled_events" => ["*"]}])

    assert {:ok, %WebhookEndpoint{id: "we_1", secret: "whsec_new", enabled_events: events}} =
             WebhookEndpoint.ensure("site-a", @url)

    assert Enum.sort(events) == handled()
    assert_received {:write, "/v1/webhook_endpoints", form}
    assert {"api_version", Stripe.version()} in form
    assert {"url", @url} in form
  end

  test "an endpoint missing events gets them added, keeping its own" do
    stripe([
      %{"id" => "we_1", "url" => @url, "enabled_events" => ["invoice.paid", "account.updated"]}
    ])

    assert {:ok, %{missing: missing}} = WebhookEndpoint.check("site-a", @url)
    assert missing == handled() -- ["invoice.paid"]
    refute_received {:write, _path, _form}

    assert {:ok, %WebhookEndpoint{secret: nil, enabled_events: events}} =
             WebhookEndpoint.ensure("site-a", @url)

    assert "account.updated" in events
    assert Enum.all?(handled(), &(&1 in events))
    assert_received {:write, "/v1/webhook_endpoints/we_1", _form}
  end

  test "an endpoint with every event, or all of them, is left as it is" do
    for events <- [["*"], handled()] do
      stripe([%{"id" => "we_1", "url" => @url, "enabled_events" => events}])
      assert {:ok, %{missing: []}} = WebhookEndpoint.check("site-a", @url)
      assert {:ok, %WebhookEndpoint{id: "we_1"}} = WebhookEndpoint.ensure("site-a", @url)
      refute_received {:write, _path, _form}
    end
  end

  test "an address that is not an https URL is refused before any request" do
    MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)

    for url <- ["not a url", "ftp://shop.test/x", "http://shop.test/pay", ""] do
      assert {:error, %MishkaPay.Errors.Invalid{errors: [%{field: :url}]}} =
               WebhookEndpoint.check("site-a", url)

      assert {:error, %MishkaPay.Errors.Invalid{}} = WebhookEndpoint.ensure("site-a", url)
    end
  end

  test "no endpoint at the URL is said, and a wrong id is refused before any request" do
    stripe([])
    assert {:ok, %{endpoint: nil, missing: missing}} = WebhookEndpoint.check("site-a", @url)
    assert missing == handled()

    assert {:error, %MishkaPay.Errors.Invalid{errors: [%{field: :endpoint_id}]}} =
             WebhookEndpoint.delete("site-a", "../v1/charges")
  end
end

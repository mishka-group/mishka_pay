# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.CheckTest do
  # Starts plugins and shares the sandboxed database with their tasks.
  use MishkaPay.DataCase, async: false

  alias MishkaPay.Check
  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Support.Domain

  @url "https://shop.test/pay/webhooks/stripe/site-a"

  defp stripe(endpoint_events) do
    MishkaPay.Test.stub_http(fn conn ->
      case conn.request_path do
        "/v1/customers" ->
          Req.Test.json(conn, %{"data" => [], "has_more" => false})

        "/v2/core/event_destinations" ->
          destination = %{
            "id" => "ed_test_1",
            "object" => "v2.core.event_destination",
            "event_payload" => "thin",
            "webhook_endpoint" => %{"url" => @url},
            "enabled_events" => endpoint_events
          }

          Req.Test.json(conn, %{"data" => [destination], "next_page_url" => nil})
      end
    end)
  end

  test "a provider that is not installed is the only check" do
    assert [{:provider, {:error, _reason}}] = Check.run(provider: "stripe", tenant: "site-a")
  end

  test "a site without keys says so, and one with keys has them tried, its secret and endpoint checked" do
    MishkaPay.Test.start_plugin!(Stripe)
    assert [{:provider, :ok}, {:keys, {:error, _no_keys}}] = Check.run(tenant: "nowhere")

    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_a"}, "site-a")
    stripe(["v1.invoice.paid"])

    results = Check.run(tenant: "site-a", webhook_url: @url)

    assert [
             provider: :ok,
             keys: :ok,
             keys_accepted: :ok,
             webhook_secret: {:error, _no_secret},
             webhook_endpoint: {:error, missing}
           ] = results

    assert missing =~ "checkout.session.completed"
    refute Check.ok?(results)

    MishkaPay.Test.put_keys(
      "stripe",
      %{secret_key: "sk_test_a", webhook_secret: "whsec_a"},
      "site-a"
    )

    stripe(["*"])
    assert Check.ok?(Check.run(tenant: "site-a", webhook_url: @url))
  end

  test "keys the provider refuses fail their check" do
    MishkaPay.Test.start_plugin!(Stripe)

    MishkaPay.Test.put_keys(
      "stripe",
      %{secret_key: "sk_test_bad", webhook_secret: "whsec_a"},
      "site-a"
    )

    MishkaPay.Test.stub_http(fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{
        "error" => %{"type" => "invalid_request_error", "message" => "Invalid API Key provided"}
      })
    end)

    assert {:keys_accepted, {:error, _refused}} =
             List.keyfind(Check.run(tenant: "site-a"), :keys_accepted, 0)
  end

  test "an Ash domain's listeners must be started, and its inbox worked by Oban" do
    MishkaPay.Test.start_plugin!(Stripe)

    MishkaPay.Test.put_keys(
      "stripe",
      %{secret_key: "sk_test_a", webhook_secret: "whsec_a"},
      "site-a"
    )

    stripe(["*"])

    results = Check.run(tenant: "site-a", domain: Domain)
    assert {:listeners, {:error, idle}} = List.keyfind(results, :listeners, 0)
    assert idle =~ "MishkaPay.Support.Payment.MishkaPayListener"

    for listener <- MishkaPay.Ash.listeners(Domain), do: MishkaPay.Test.start_plugin!(listener)

    results = Check.run(tenant: "site-a", domain: Domain)
    assert {:listeners, :ok} = List.keyfind(results, :listeners, 0)
    # The test Oban runs no queues (testing: :manual), as a node that forgot the inbox queue.
    assert {:inbox, {:error, "Oban does not run the mishka_pay_inbox queue"}} =
             List.keyfind(results, :inbox, 0)

    assert {:inbox, {:error, "MishkaPay.Support.Options has no kind :inbox resource"}} =
             tenant_check(MishkaPay.Support.Options)
  end

  defp tenant_check(domain) do
    [tenant: "site-a", domain: domain] |> Check.run() |> List.keyfind(:inbox, 0)
  end
end

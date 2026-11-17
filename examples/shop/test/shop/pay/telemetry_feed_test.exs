defmodule Shop.Pay.TelemetryFeedTest do
  use ExUnit.Case, async: true

  alias Shop.Pay.TelemetryFeed

  setup do
    Phoenix.PubSub.subscribe(Shop.PubSub, TelemetryFeed.topic())
  end

  test "a request the provider limited shows the reason it gave, and any other only its path" do
    meta = %{provider: "stripe", method: :get, path: "/v1/feed_test", status: 429}

    TelemetryFeed.handle(
      [:mishka_pay, :request, :retry],
      %{wait: 500},
      Map.put(meta, :rate_limit_reason, "endpoint-concurrency"),
      nil
    )

    assert_receive {:telemetry, %{event: "request.retry", detail: detail, outcome: 429}}

    assert detail == "GET /v1/feed_test · rate limited: endpoint-concurrency"

    TelemetryFeed.handle([:mishka_pay, :request, :stop], %{duration: 1}, meta, nil)
    assert_receive {:telemetry, %{event: "request", detail: "GET /v1/feed_test"}}
  end
end

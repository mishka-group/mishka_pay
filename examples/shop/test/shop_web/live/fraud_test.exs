defmodule ShopWeb.FraudTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  defp review(id),
    do: %{
      "object" => "review",
      "id" => id,
      "charge" => "ch_1",
      "payment_intent" => "pi_1",
      "open" => true,
      "opened_reason" => "rule",
      "reason" => "rule",
      "created" => 1_790_000_000
    }

  setup do
    test = self()

    StripeStub.stub(fn
      "GET", "/v1/radar/early_fraud_warnings", _params ->
        send(test, :warnings_read)

        StripeStub.list([
          %{
            "object" => "radar.early_fraud_warning",
            "id" => "issfr_1",
            "charge" => "ch_9",
            "payment_intent" => "pi_9",
            "fraud_type" => "made_with_stolen_card",
            "actionable" => true,
            "created" => 1_790_000_000
          }
        ])

      "GET", "/v1/reviews", _params ->
        StripeStub.list([review("prv_1"), review("prv_2"), review("prv_gone")])

      "POST", "/v1/reviews/prv_1/approve", _params ->
        send(test, {:approved, "prv_1"})
        Map.merge(review("prv_1"), %{"open" => false, "closed_reason" => "approved"})

      _method, _path, _params ->
        nil
    end)

    :ok
  end

  test "nothing is read until shown; then warnings and open reviews show, and one is approved",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    refute_received :warnings_read
    refute has_element?(view, "[data-testid=fraud-warning-rows]")

    view |> element("[data-testid=fraud-show]") |> render_click()
    render_async(view)
    assert_received :warnings_read

    assert has_element?(
             view,
             "[data-warning-id=issfr_1] [data-testid=fraud-warning-actionable]",
             "yes"
           )

    assert has_element?(view, "[data-testid=fraud-review-row][data-review-id=prv_2]")

    view
    |> element("[data-review-id=prv_1] [data-testid=fraud-review-approve]")
    |> render_click()

    assert_received {:approved, "prv_1"}
    assert has_element?(view, "[data-testid=fraud-notice]", "prv_1")
    refute has_element?(view, "[data-testid=fraud-review-row][data-review-id=prv_1]")
    assert has_element?(view, "[data-testid=fraud-review-row][data-review-id=prv_2]")
  end

  test "a review Stripe no longer has says so, and nothing else changes", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view |> element("[data-testid=fraud-show]") |> render_click()
    render_async(view)

    view
    |> element("[data-review-id=prv_gone] [data-testid=fraud-review-approve]")
    |> render_click()

    assert has_element?(view, "[data-testid=fraud-error]")
    assert has_element?(view, "[data-testid=fraud-review-row][data-review-id=prv_gone]")
  end
end

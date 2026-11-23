defmodule ShopWeb.WebhookAnswersTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  test "the inbox shows how long each webhook took to answer, and the refused messages are counted",
       %{conn: conn} do
    StripeStub.stub(fn _method, _path, _params -> nil end)

    event =
      Ash.create!(
        Shop.Pay.WebhookEvent,
        %{provider: "stripe", tenant: "demo", event_id: "evt_timed", type: "charge.updated"},
        action: :receive,
        authorize?: false
      )

    Ash.update!(event, %{answer_ms: 42, answer_status: 200}, action: :answered, authorize?: false)

    for _twice <- 1..2 do
      Ash.create!(
        Shop.Pay.WebhookRejection,
        %{
          provider: "stripe",
          tenant: "demo",
          reason: "mismatch",
          day: Date.utc_today(),
          last_at: DateTime.utc_now()
        },
        action: :count,
        authorize?: false
      )
    end

    {:ok, view, _html} = live(conn, "/")

    assert has_element?(
             view,
             "[data-testid=inbox-row][data-event-id=evt_timed] [data-testid=inbox-answer]",
             "42 ms (200)"
           )

    assert has_element?(view, "[data-testid=rejections-total]", "2")

    assert has_element?(
             view,
             "[data-testid=rejection-row][data-reason=mismatch] [data-testid=rejection-count]",
             "2"
           )
  end
end

defmodule ShopWeb.PayoutsTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  defp settings(schedule, delay),
    do: %{
      "object" => "balance_settings",
      "payments" => %{
        "payouts" => %{
          "schedule" => schedule,
          "minimum_balance_by_currency" => %{"usd" => 1500},
          "status" => "enabled"
        },
        "settlement_timing" => %{"delay_days" => delay}
      }
    }

  test "reads the payout schedule and sets a weekly one", %{conn: conn} do
    test = self()

    StripeStub.stub(fn
      "GET", "/v1/balance_settings", _params ->
        settings(%{"interval" => "monthly", "monthly_payout_days" => [21]}, 3)

      "POST", "/v1/balance_settings", params ->
        send(test, {:schedule, params})

        settings(
          %{"interval" => "weekly", "weekly_payout_days" => ["monday", "friday"]},
          7
        )

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")

    view |> element("[data-testid=payout-schedule-read]") |> render_click()
    assert has_element?(view, "[data-testid=payout-schedule-interval]", "monthly")
    assert has_element?(view, "[data-testid=payout-schedule-days]", "21")
    assert has_element?(view, "[data-testid=payout-schedule-delay]", "3")
    assert has_element?(view, "[data-testid=payout-schedule-minimum-balances]", "$15.00")

    assert has_element?(
             view,
             "[data-testid=payout-schedule-minimum-payouts]",
             "Stripe's API does not say"
           )

    form = "[data-testid=payout-schedule-form]"
    view |> form(form, %{interval: "weekly"}) |> render_change()

    view
    |> form(form, %{weekly_days: ["", "monday", "friday"], delay_days: "7"})
    |> render_submit()

    assert_received {:schedule,
                     %{
                       "payments" => %{
                         "payouts" => %{
                           "schedule" => %{
                             "interval" => "weekly",
                             "weekly_payout_days" => %{"0" => "monday", "1" => "friday"}
                           }
                         },
                         "settlement_timing" => %{"delay_days_override" => "7"}
                       }
                     }}

    assert has_element?(view, "[data-testid=payout-schedule-interval]", "weekly")
    assert has_element?(view, "[data-testid=payouts-notice]")
  end

  test "a weekly schedule without its days is refused before Stripe", %{conn: conn} do
    StripeStub.stub(fn
      _method, "/v1/balance_settings", _params -> flunk("the schedule reached Stripe")
      _method, _path, _params -> nil
    end)

    {:ok, view, _html} = live(conn, "/")
    form = "[data-testid=payout-schedule-form]"
    view |> form(form, %{interval: "weekly"}) |> render_change()
    view |> form(form) |> render_submit()

    assert has_element?(view, "[data-testid=payouts-error]")
  end

  test "lists the banks payouts go to, with their last four digits", %{conn: conn} do
    StripeStub.stub(fn
      "GET", "/v1/account", _params ->
        %{"id" => "acct_shop", "object" => "account"}

      "GET", "/v1/accounts/acct_shop/external_accounts", _params ->
        StripeStub.list([
          %{
            "id" => "ba_1",
            "object" => "bank_account",
            "bank_name" => "STRIPE TEST BANK",
            "last4" => "6789",
            "currency" => "usd",
            "default_for_currency" => true
          }
        ])

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")
    view |> element("[data-testid=payout-destinations-read]") |> render_click()

    assert has_element?(
             view,
             "[data-destination-id=ba_1] [data-testid=payout-destination-bank]",
             "STRIPE TEST BANK"
           )

    assert has_element?(
             view,
             "[data-destination-id=ba_1] [data-testid=payout-destination-last4]",
             "6789"
           )
  end

  test "pays out now, and shows Stripe's refusal when the balance lacks the money", %{conn: conn} do
    test = self()

    StripeStub.stub(fn
      "POST", "/v1/payouts", %{"currency" => "usd"} = params ->
        send(test, {:payout, params})

        %{
          "id" => "po_1",
          "object" => "payout",
          "amount" => 100,
          "currency" => "usd",
          "status" => "pending",
          "method" => "instant"
        }

      "POST", "/v1/payouts", _params ->
        StripeStub.error(
          "You have insufficient funds in your Stripe account.",
          "balance_insufficient"
        )

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")
    form = "[data-testid=payout-form]"

    view |> form(form, %{amount: "1.00", currency: "USD", method: "instant"}) |> render_submit()

    assert_received {:payout, %{"amount" => "100", "method" => "instant"}}
    assert has_element?(view, "[data-testid=payout-made]", "po_1")

    view |> form(form, %{amount: "1.00", currency: "EUR"}) |> render_submit()
    assert has_element?(view, "[data-testid=payouts-error]")
    refute has_element?(view, "[data-testid=payout-made]")
  end
end

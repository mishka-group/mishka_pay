defmodule ShopWeb.SubscriptionScheduleComponentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  @start 1_794_000_000
  @end_ 1_796_592_000

  test "a plan change on a date makes a schedule from the subscription, shows its phases, and releases it",
       %{conn: conn} do
    team_plan()

    StripeRoutes.stub(%{
      {"GET", "/v1/subscriptions/sub_ada"} => subscription(nil),
      {"POST", "/v1/subscription_schedules"} => schedule("active", [phase(@start, @end_)]),
      {"POST", "/v1/subscription_schedules/sub_sched_1"} => fn
        %{"phases" => _phases} -> schedule("active", two_phases())
        _labels -> schedule("active", [phase(@start, @end_)])
      end,
      {"POST", "/v1/subscription_schedules/sub_sched_1/release"} =>
        schedule("released", two_phases())
    })

    view = open_subscription(conn)
    refute_received {:stripe, _method, "/v1/subscription_schedules" <> _, _params}
    refute has_element?(view, "[data-testid=schedule-show]")

    view |> element("[data-testid=schedule-open]") |> render_click()
    date = Date.utc_today() |> Date.add(10) |> Date.to_iso8601()

    view
    |> form("[data-testid=schedule-form]", %{
      "how" => "next_plan",
      "price_id" => "price_team",
      "date" => date
    })
    |> render_submit()

    assert_received {:stripe, "POST", "/v1/subscription_schedules",
                     %{"from_subscription" => "sub_ada"}}

    assert_received {:stripe, "POST", "/v1/subscription_schedules/sub_sched_1",
                     %{"metadata" => %{"mishka_pay_reference" => "shop-schedule-sub_ada"}}}

    assert_received {:stripe, "POST", "/v1/subscription_schedules/sub_sched_1", change}

    assert %{
             "end_behavior" => "release",
             "phases" => %{
               "0" => %{
                 "start_date" => start,
                 "end_date" => end_date,
                 "items" => %{"0" => %{"price" => "price_pro", "quantity" => "1"}}
               },
               "1" => %{"items" => %{"0" => %{"price" => "price_team", "quantity" => "1"}}}
             }
           } = change

    assert start == Integer.to_string(@start)

    assert end_date ==
             date
             |> Date.from_iso8601!()
             |> DateTime.new!(~T[00:00:00])
             |> DateTime.to_unix()
             |> Integer.to_string()

    assert has_element?(view, "[data-testid=schedule-phase][data-current=true]")
    assert view |> element("[data-testid=schedule-end]") |> render() =~ "release"

    view |> element("[data-testid=schedule-release]") |> render_click()
    assert_received {:stripe, "POST", "/v1/subscription_schedules/sub_sched_1/release", _params}
    assert view |> element("[data-testid=schedule-status]") |> render() =~ "released"
    refute has_element?(view, "[data-testid=schedule-release]")
  end

  test "a subscription with a schedule shows it when asked, stops after some periods, and cancels",
       %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/subscriptions/sub_ada"} => subscription("sub_sched_1"),
      {"GET", "/v1/subscription_schedules/sub_sched_1"} =>
        schedule("active", [phase(@start, @end_)]),
      {"POST", "/v1/subscription_schedules/sub_sched_1"} =>
        Map.put(schedule("active", [phase(@start, @end_)]), "end_behavior", "cancel"),
      {"POST", "/v1/subscription_schedules/sub_sched_1/cancel"} =>
        schedule("canceled", [phase(@start, @end_)])
    })

    view = open_subscription(conn)
    refute_received {:stripe, "GET", "/v1/subscription_schedules/sub_sched_1", _params}

    view |> element("[data-testid=schedule-show]") |> render_click()
    render_async(view)
    assert_received {:stripe, "GET", "/v1/subscription_schedules/sub_sched_1", _params}
    assert has_element?(view, "[data-testid=schedule-card]")

    view |> element("[data-testid=schedule-open]") |> render_click()
    view |> form("[data-testid=schedule-form]", %{"how" => "stop_after"}) |> render_change()

    view
    |> form("[data-testid=schedule-form]", %{"how" => "stop_after", "periods" => "4"})
    |> render_submit()

    refute_received {:stripe, "POST", "/v1/subscription_schedules", _params}
    assert_received {:stripe, "POST", "/v1/subscription_schedules/sub_sched_1", change}

    assert %{
             "end_behavior" => "cancel",
             "phases" => %{
               "0" => %{"duration" => %{"interval" => "month", "interval_count" => "4"}} = now
             }
           } = change

    refute Map.has_key?(now, "end_date")

    view |> element("[data-testid=schedule-cancel]") |> render_click()
    assert_received {:stripe, "POST", "/v1/subscription_schedules/sub_sched_1/cancel", _params}
    assert view |> element("[data-testid=schedule-status]") |> render() =~ "canceled"
  end

  test "the plan picked stays picked when another field changes, and is the one sent",
       %{conn: conn} do
    plan("pro-monthly", "price_pro", 1)
    team_plan()

    StripeRoutes.stub(%{
      {"GET", "/v1/subscriptions/sub_ada"} => subscription(nil),
      {"POST", "/v1/subscription_schedules"} => schedule("active", [phase(@start, @end_)]),
      {"POST", "/v1/subscription_schedules/sub_sched_1"} => schedule("active", two_phases())
    })

    view = open_subscription(conn)
    view |> element("[data-testid=schedule-open]") |> render_click()
    date = Date.utc_today() |> Date.add(10) |> Date.to_iso8601()

    view |> form("[data-testid=schedule-form]", %{"price_id" => "price_team"}) |> render_change()
    view |> form("[data-testid=schedule-form]", %{"date" => date}) |> render_change()
    assert has_element?(view, "[data-testid=schedule-plan] option[value=price_team][selected]")

    view |> form("[data-testid=schedule-form]") |> render_submit()

    assert_received {:stripe, "POST", "/v1/subscription_schedules/sub_sched_1",
                     %{"phases" => %{"1" => %{"items" => %{"0" => %{"price" => "price_team"}}}}}}
  end

  test "a date gone by or no periods is refused before Stripe is asked", %{conn: conn} do
    team_plan()
    StripeRoutes.stub(%{{"GET", "/v1/subscriptions/sub_ada"} => subscription(nil)})

    view = open_subscription(conn)
    view |> element("[data-testid=schedule-open]") |> render_click()

    view
    |> form("[data-testid=schedule-form]", %{"price_id" => "price_team", "date" => "2020-01-01"})
    |> render_submit()

    assert view |> element("#flash-error") |> render() =~ "date still to come"

    view |> form("[data-testid=schedule-form]", %{"how" => "stop_after"}) |> render_change()

    view
    |> form("[data-testid=schedule-form]", %{"how" => "stop_after", "periods" => "0"})
    |> render_submit()

    refute_received {:stripe, "POST", "/v1/subscription_schedules" <> _, _params}
  end

  defp open_subscription(conn) do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=read-subscription-form]", %{"subscription_id" => "sub_ada"})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "[data-testid=subscription-schedule]")
    view
  end

  defp team_plan, do: plan("team-monthly", "price_team", 2)

  defp plan(slug, price_id, position) do
    plan =
      Ash.create!(
        Shop.Catalog.Product,
        %{slug: slug, name: slug, price: "19.00", interval: :month, position: position},
        action: :seed,
        authorize?: false
      )

    Ash.update!(plan, %{stripe_price_id: price_id}, action: :published, authorize?: false)
  end

  defp subscription(schedule_id) do
    %{
      "object" => "subscription",
      "id" => "sub_ada",
      "status" => "active",
      "customer" => %{"object" => "customer", "id" => "cus_ada", "email" => "ada@shop.test"},
      "schedule" => schedule_id,
      "metadata" => %{},
      "items" => %{
        "object" => "list",
        "data" => [
          %{
            "id" => "si_1",
            "quantity" => 1,
            "current_period_start" => @start,
            "current_period_end" => @end_,
            "price" => %{
              "id" => "price_pro",
              "product" => %{"id" => "prod_pro", "name" => "Pro"},
              "unit_amount" => 900,
              "currency" => "usd",
              "recurring" => %{"interval" => "month", "interval_count" => 1}
            }
          }
        ]
      }
    }
  end

  defp schedule(status, phases) do
    %{
      "object" => "subscription_schedule",
      "id" => "sub_sched_1",
      "customer" => "cus_ada",
      "subscription" => if(status in ["released", "canceled"], do: nil, else: "sub_ada"),
      "released_subscription" => if(status == "released", do: "sub_ada"),
      "status" => status,
      "end_behavior" => "release",
      "current_phase" => %{"start_date" => @start, "end_date" => @end_},
      "phases" => phases
    }
  end

  defp phase(start, finish, price \\ "price_pro") do
    %{
      "start_date" => start,
      "end_date" => finish,
      "items" => [%{"price" => price, "quantity" => 1}],
      "proration_behavior" => "create_prorations"
    }
  end

  defp two_phases,
    do: [phase(@start, @end_), phase(@end_, @end_ + 2_592_000, "price_team")]
end

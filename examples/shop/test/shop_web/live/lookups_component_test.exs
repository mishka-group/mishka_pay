defmodule ShopWeb.LookupsComponentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  test "customers are found by email and reference together", %{conn: conn} do
    StripeStub.stub(%{
      {"GET", "/v1/customers/search"} =>
        StripeStub.list([
          %{
            "object" => "customer",
            "id" => "cus_ada",
            "email" => "ada@example.com",
            "name" => "Ada",
            "metadata" => %{"mishka_pay_reference" => "user-1"}
          }
        ])
    })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=customer-search-form]", email: "ada@example.com", reference: "user-1")
    |> render_submit()

    assert_received {:stripe, "GET", "/v1/customers/search", %{"query" => query}}
    assert query =~ "email:'ada@example.com'"
    assert query =~ "user-1"

    assert view
           |> element("[data-testid=customer-search-result][data-customer-id=cus_ada]")
           |> render() =~ "ref user-1"
  end

  test "a search with nothing typed is refused, and no match says so", %{conn: conn} do
    StripeStub.stub(%{{"GET", "/v1/customers/search"} => StripeStub.list([])})
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("[data-testid=customer-search-form]") |> render_submit()
    refute_received {:stripe, "GET", "/v1/customers/search", _params}
    assert render(view) =~ "Type an email"

    view |> form("[data-testid=customer-search-form]", name: "Nobody") |> render_submit()
    assert has_element?(view, "[data-testid=customer-search-empty]")
  end

  test "a subscription's next bill is read without changing it", %{conn: conn} do
    StripeStub.stub(%{{"POST", "/v1/invoices/create_preview"} => preview(900)})
    row = seed_subscription()
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=sub-bill-form]", subscription: row.id)
    |> render_submit(%{"do" => "next"})

    assert_received {:stripe, "POST", "/v1/invoices/create_preview",
                     %{"subscription" => "sub_ada"}}

    assert view |> element("[data-testid=sub-bill-title]") |> render() =~ "Next bill"
    assert view |> element("[data-testid=sub-bill-due]") |> render() =~ "$9.00"
  end

  test "a quantity change is previewed with its bill", %{conn: conn} do
    StripeStub.stub(%{
      {"GET", "/v1/subscriptions/sub_ada"} => %{
        "object" => "subscription",
        "id" => "sub_ada",
        "status" => "active",
        "customer" => "cus_ada",
        "items" =>
          StripeStub.list([
            %{
              "id" => "si_ada",
              "quantity" => 1,
              "price" => %{"id" => "price_pro", "unit_amount" => 900, "currency" => "usd"}
            }
          ])
      },
      {"POST", "/v1/invoices/create_preview"} => preview(1800)
    })

    row = seed_subscription()
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=sub-bill-form]", subscription: row.id, quantity: "2")
    |> render_submit(%{"do" => "preview"})

    assert_received {:stripe, "POST", "/v1/invoices/create_preview", params}

    assert [%{"id" => "si_ada", "quantity" => "2"}] =
             Map.values(params["subscription_details"]["items"])

    assert view |> element("[data-testid=sub-bill-title]") |> render() =~ "If the change is made"
    assert view |> element("[data-testid=sub-bill-due]") |> render() =~ "$18.00"
  end

  test "no subscription picked is refused in plain words", %{conn: conn} do
    StripeStub.stub(%{})
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("[data-testid=sub-bill-form]") |> render_submit(%{"do" => "next"})

    refute_received {:stripe, "POST", "/v1/invoices/create_preview", _params}
    assert render(view) =~ "Pick a subscription"
  end

  defp preview(amount) do
    %{
      "object" => "invoice",
      "id" => "upcoming_in",
      "status" => "draft",
      "currency" => "usd",
      "amount_due" => amount,
      "amount_paid" => 0,
      "total" => amount,
      "lines" => StripeStub.list([%{"description" => "Pro plan", "amount" => amount}])
    }
  end

  defp seed_subscription do
    Ash.Seed.seed!(Shop.Pay.Subscription, %{
      provider: "stripe",
      provider_id: "sub_ada",
      tenant: "demo",
      status: :active,
      plan: "Pro plan",
      synced_at: DateTime.utc_now()
    })
  end
end

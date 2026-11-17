defmodule ShopWeb.CustomersComponentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  @ada %{
    "object" => "customer",
    "id" => "cus_ada",
    "email" => "ada@example.com",
    "name" => "Ada",
    "metadata" => %{}
  }

  test "Delete asks first, deletes the customer on Stripe and keeps the row, marked deleted", %{
    conn: conn
  } do
    StripeRoutes.stub(%{
      {"GET", "/v1/customers/cus_ada"} => @ada,
      {"DELETE", "/v1/customers/cus_ada"} => %{
        "object" => "customer",
        "id" => "cus_ada",
        "deleted" => true
      }
    })

    row = seed_customer()
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=customer-row][data-customer-id=cus_ada]") |> render_click()

    delete = element(view, "[data-testid=customer-delete]")
    assert render(delete) =~ "data-confirm="
    render_click(delete)

    assert_received {:stripe, "DELETE", "/v1/customers/cus_ada", _params}
    assert Ash.get!(Shop.Pay.Customer, row.id, authorize?: false).deleted_at

    assert has_element?(
             view,
             "[data-testid=customer-row][data-customer-id=cus_ada][data-deleted=true]"
           )

    assert has_element?(view, "[data-testid=customer-deleted-note]")
    refute has_element?(view, "[data-testid=customer-delete]")
    refute has_element?(view, "[data-testid=customer-edit-form]")
  end

  test "a delete Stripe refuses says so and leaves the row as it was", %{conn: conn} do
    StripeRoutes.stub(%{{"GET", "/v1/customers/cus_ada"} => @ada})
    row = seed_customer()
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=customer-row][data-customer-id=cus_ada]") |> render_click()

    view |> element("[data-testid=customer-delete]") |> render_click()

    assert_received {:stripe, "DELETE", "/v1/customers/cus_ada", _params}
    assert view |> element("#flash-error") |> render() =~ "Stripe refused the request"
    assert Ash.get!(Shop.Pay.Customer, row.id, authorize?: false).deleted_at == nil
    assert has_element?(view, "[data-testid=customer-delete]")
  end

  @grace %{
    "id" => "acct_grace",
    "object" => "v2.core.account",
    "applied_configurations" => ["customer"],
    "closed" => false,
    "contact_email" => "grace@example.com",
    "display_name" => "Grace",
    "created" => "2026-11-17T12:36:17.000Z",
    "metadata" => %{}
  }

  test "New customer makes an Accounts v2 customer by default, and a v1 Customer when chosen", %{
    conn: conn
  } do
    StripeRoutes.stub(%{
      {"POST", "/v2/core/accounts"} => @grace,
      {"POST", "/v1/customers"} => @ada
    })

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=new-customer-toggle]") |> render_click()

    view
    |> form("[data-testid=new-customer-form]", email: "grace@example.com", name: "Grace")
    |> render_submit()

    assert_received {:stripe, "POST", "/v2/core/accounts", %{}}
    assert has_element?(view, "[data-testid=customer-row][data-customer-id=acct_grace]")

    view |> element("[data-testid=new-customer-toggle]") |> render_click()

    view
    |> form("[data-testid=new-customer-form]", email: "ada@example.com", api: "v1")
    |> render_submit()

    assert_received {:stripe, "POST", "/v1/customers", %{"email" => "ada@example.com"}}
    assert has_element?(view, "[data-testid=customer-row][data-customer-id=cus_ada]")
  end

  test "Find on Stripe searches by email, which finds v2 customers by their account, and lists the newest without one",
       %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/customers/search"} =>
        StripeRoutes.list([Map.put(@ada, "customer_account", "acct_grace")]),
      {"GET", "/v2/core/accounts"} => %{"data" => [@grace], "next_page_url" => nil}
    })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=find-customer-form]", email: "ada@example.com")
    |> render_submit()

    assert_received {:stripe, "GET", "/v1/customers/search", %{"query" => query}}
    assert query =~ "ada@example.com"
    assert has_element?(view, "[data-testid=found-customer][data-customer-id=acct_grace]")

    view |> form("[data-testid=find-customer-form]", email: "") |> render_submit()

    assert_received {:stripe, "GET", "/v2/core/accounts",
                     %{"applied_configurations" => %{"0" => "customer"}}}
  end

  test "buying as a v2 customer sends it as customer_account, with merchant of record off", %{
    conn: conn
  } do
    StripeRoutes.stub(%{
      {"GET", "/v2/core/accounts/acct_grace"} => @grace,
      {"POST", "/v1/checkout/sessions"} => %{
        "object" => "checkout.session",
        "id" => "cs_test_grace",
        "url" => "https://checkout.stripe.com/c/pay/cs_test_grace",
        "status" => "open"
      }
    })

    Ash.create!(
      Shop.Catalog.Product,
      %{slug: "hoodie", name: "Elixir hoodie", price: "39.00", interval: nil, position: 1},
      action: :seed,
      authorize?: false
    )

    row = seed_customer(%{provider_id: "acct_grace", email: "grace@example.com"})
    {:ok, view, _html} = live(conn, ~p"/?buyer=#{row.id}")
    assert has_element?(view, "[data-testid=buyer-v2-note]")

    assert {:error, {:redirect, %{to: "https://checkout.stripe.com/c/pay/cs_test_grace"}}} =
             view |> form("#buy") |> render_submit(%{"product" => "hoodie"})

    assert_received {:stripe, "POST", "/v1/checkout/sessions", params}
    assert params["customer_account"] == "acct_grace"
    refute Map.has_key?(params, "customer")
    assert params["managed_payments"] == %{"enabled" => "false"}
  end

  defp seed_customer(attrs \\ %{}) do
    customer =
      Map.merge(
        %{
          provider: "stripe",
          provider_id: "cus_ada",
          tenant: "demo",
          email: "ada@example.com",
          name: "Ada",
          metadata: %{},
          synced_at: DateTime.utc_now()
        },
        attrs
      )

    Ash.Seed.seed!(Shop.Pay.Customer, customer)
  end
end

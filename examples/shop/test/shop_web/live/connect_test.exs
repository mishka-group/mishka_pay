defmodule ShopWeb.ConnectTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  defp account(id, extra \\ %{}),
    do:
      Map.merge(
        %{
          "object" => "account",
          "id" => id,
          "email" => "#{id}@example.com",
          "controller" => %{"stripe_dashboard" => %{"type" => "express"}},
          "charges_enabled" => false,
          "payouts_enabled" => false,
          "requirements" => %{"currently_due" => ["external_account", "tos_acceptance.date"]},
          "metadata" => %{},
          "created" => 1_790_000_000
        },
        extra
      )

  setup do
    test = self()

    StripeStub.stub(fn
      "GET", "/v1/accounts", _params ->
        send(test, :accounts_read)
        StripeStub.list([account("acct_1", %{"charges_enabled" => true})])

      "POST", "/v1/accounts", params ->
        send(test, {:made, params})
        account("acct_new", %{"email" => params["email"]})

      "POST", "/v1/account_links", %{"account" => "acct_1"} = params ->
        send(test, {:linked, params})

        %{
          "object" => "account_link",
          "url" => "https://connect.stripe.com/setup/e/acct_1/abc",
          "expires_at" => 1_790_000_300,
          "created" => 1_790_000_000
        }

      _method, _path, _params ->
        nil
    end)

    :ok
  end

  test "nothing is read until shown; then the accounts list, one is made and one onboarded",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    refute_received :accounts_read
    refute has_element?(view, "[data-testid=connect-account-rows]")

    view |> element("[data-testid=connect-show]") |> render_click()
    render_async(view)
    assert_received :accounts_read

    assert has_element?(
             view,
             "[data-account-id=acct_1] [data-testid=connect-account-charges]",
             "yes"
           )

    assert has_element?(view, "[data-account-id=acct_1] [data-testid=connect-account-due]", "2")

    view
    |> form("[data-testid=connect-create-form]", %{email: "ava@example.com", country: "DE"})
    |> render_submit()

    assert_received {:made, made}

    assert %{
             "country" => "DE",
             "email" => "ava@example.com",
             "controller" => %{"stripe_dashboard" => %{"type" => "express"}},
             "capabilities" => %{"transfers" => %{"requested" => "true"}}
           } = made

    assert has_element?(view, "[data-testid=connect-notice]", "acct_new")
    assert has_element?(view, "[data-testid=connect-account-row][data-account-id=acct_new]")

    view
    |> element("[data-account-id=acct_1] [data-testid=connect-account-onboard]")
    |> render_click()

    assert_received {:linked, %{"type" => "account_onboarding", "return_url" => "http" <> _}}

    assert has_element?(
             view,
             "[data-testid=connect-link-url][href='https://connect.stripe.com/setup/e/acct_1/abc']"
           )
  end

  test "a sandbox that has not signed up for Connect says so, and a failed link changes nothing",
       %{conn: conn} do
    StripeStub.stub(fn
      "POST", "/v1/accounts", _params ->
        StripeStub.error(
          "You can only create new accounts if you've signed up for Connect, which you can do at https://dashboard.stripe.com/connect.",
          nil
        )

      "GET", "/v1/accounts", _params ->
        StripeStub.list([account("acct_2")])

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")
    view |> element("[data-testid=connect-show]") |> render_click()
    render_async(view)

    view |> form("[data-testid=connect-create-form]", %{country: "US"}) |> render_submit()
    assert has_element?(view, "[data-testid=connect-error]", "signed up for Connect")

    view
    |> element("[data-account-id=acct_2] [data-testid=connect-account-onboard]")
    |> render_click()

    assert has_element?(view, "[data-testid=connect-error]")
    refute has_element?(view, "[data-testid=connect-link]")
    assert has_element?(view, "[data-testid=connect-account-row][data-account-id=acct_2]")
  end
end

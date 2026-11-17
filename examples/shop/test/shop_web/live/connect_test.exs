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

      "GET", "/v1/payouts", _params ->
        StripeStub.list([
          %{
            "object" => "payout",
            "id" => "po_1",
            "amount" => 4200,
            "currency" => "usd",
            "status" => "in_transit",
            "arrival_date" => 1_790_100_000,
            "automatic" => true
          }
        ])

      "GET", "/v1/application_fees", _params ->
        StripeStub.list([
          %{
            "object" => "application_fee",
            "id" => "fee_1",
            "amount" => 250,
            "amount_refunded" => 0,
            "currency" => "usd",
            "account" => "acct_1",
            "charge" => "ch_1"
          }
        ])

      "POST", "/v1/transfers", params ->
        send(test, {:sent, params})
        transfer(params["destination"], 0)

      "POST", "/v1/transfers/tr_new/reversals", _params ->
        send(test, :reversed)
        %{"object" => "transfer_reversal", "id" => "trr_1", "transfer" => transfer("acct_1", 500)}

      _method, _path, _params ->
        nil
    end)

    :ok
  end

  defp transfer(destination, reversed),
    do: %{
      "object" => "transfer",
      "id" => "tr_new",
      "amount" => 500,
      "amount_reversed" => reversed,
      "reversed" => reversed == 500,
      "currency" => "usd",
      "destination" => destination,
      "metadata" => %{}
    }

  test "money goes to a listed seller and comes back; payouts and the platform's cut show",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("[data-testid=connect-show]") |> render_click()
    render_async(view)

    assert has_element?(
             view,
             "[data-payout-id=po_1] [data-testid=connect-payout-status]",
             "in_transit"
           )

    assert has_element?(view, "[data-fee-id=fee_1] [data-testid=connect-fee-amount]", "$2.50")
    assert has_element?(view, "[data-testid=connect-transfers-empty]")

    view
    |> form("[data-testid=connect-transfer-form]", %{
      destination: "acct_1",
      amount: "5.00",
      currency: "USD"
    })
    |> render_submit()

    assert_received {:sent, sent}

    assert %{"amount" => "500", "currency" => "usd", "destination" => "acct_1"} = sent
    assert %{"metadata" => %{"mishka_pay_reference" => "shop-transfer-" <> _}} = sent
    assert has_element?(view, "[data-testid=connect-notice]", "tr_new")

    view
    |> element("[data-transfer-id=tr_new] [data-testid=connect-transfer-reverse]")
    |> render_click()

    assert_received :reversed

    assert has_element?(
             view,
             "[data-transfer-id=tr_new] [data-testid=connect-transfer-reversed]",
             "$5.00"
           )

    refute has_element?(view, "[data-transfer-id=tr_new] [data-testid=connect-transfer-reverse]")
  end

  test "what is picked in the two forms stays picked while the lists and a link change",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("[data-testid=connect-show]") |> render_click()
    render_async(view)
    make = "[data-testid=connect-create-form]"
    send_money = "[data-testid=connect-transfer-form]"

    view |> form(make, %{country: "DE"}) |> render_change()
    view |> form(make, %{email: "ava@example.com"}) |> render_change()
    view |> form(send_money, %{destination: "acct_1"}) |> render_change()
    view |> form(send_money, %{currency: "EUR"}) |> render_change()
    view |> form(send_money, %{amount: "7.00"}) |> render_change()

    view
    |> element("[data-account-id=acct_1] [data-testid=connect-account-onboard]")
    |> render_click()

    assert has_element?(view, "[data-testid=connect-country] option[value=DE][selected]")

    view |> form(make) |> render_submit()
    assert_received {:made, %{"country" => "DE", "email" => "ava@example.com"}}

    view |> form(send_money) |> render_submit()

    assert_received {:sent, %{"amount" => "700", "currency" => "eur", "destination" => "acct_1"}}
  end

  test "a transfer Stripe refuses says so and adds no row", %{conn: conn} do
    StripeStub.stub(fn
      "GET", "/v1/accounts", _params ->
        StripeStub.list([account("acct_1")])

      "POST", "/v1/transfers", _params ->
        StripeStub.error("No such destination: 'acct_1'", "resource_missing")

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")
    view |> element("[data-testid=connect-show]") |> render_click()
    render_async(view)

    view
    |> form("[data-testid=connect-transfer-form]", %{amount: "5.00", currency: "USD"})
    |> render_submit()

    assert has_element?(view, "[data-testid=connect-error]")
    refute has_element?(view, "[data-testid=connect-transfer-row]")

    view
    |> form("[data-testid=connect-transfer-form]", %{amount: "0", currency: "USD"})
    |> render_submit()

    assert has_element?(view, "[data-testid=connect-error]", "more than zero")
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

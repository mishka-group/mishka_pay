defmodule ShopWeb.AccessComponentTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  setup %{conn: conn} do
    StripeRoutes.stub(%{
      {"POST", "/v1/checkout/sessions"} => fn params ->
        %{
          "id" => "cs_test_member",
          "object" => "checkout.session",
          "url" => "https://checkout.stripe.com/c/pay/cs_test_member",
          "status" => "open",
          "mode" => params["mode"]
        }
      end
    })

    seed_plan()
    {:ok, conn: conn}
  end

  test "nobody signed in: the members-only post is locked and asks to sign in", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "[data-testid=member-sign-in-form]")
    assert has_element?(view, "[data-testid=members-post][data-open=false]")
    assert view |> element("[data-testid=members-post-locked]") |> render() =~ "sign in"
    refute has_element?(view, "[data-testid=member-subscriptions]")
  end

  test "a bad email is refused in plain words and nobody is signed in", %{conn: conn} do
    conn = post(conn, ~p"/member", %{"email" => "not an email"})
    assert redirected_to(conn) =~ "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "ada@example.com"
    assert Ash.read!(Shop.Accounts.Member, authorize?: false) == []
  end

  test "signing in twice with one email keeps one member, in lower case", %{conn: conn} do
    post(conn, ~p"/member", %{"email" => "Ada@Example.com"})
    post(conn, ~p"/member", %{"email" => " ada@example.com "})

    assert [%{email: "ada@example.com"}] = Ash.read!(Shop.Accounts.Member, authorize?: false)
  end

  test "a plan bought while signed in names the member as the checkout's owner", %{conn: conn} do
    {conn, member} = sign_in(conn, "ada@example.com")
    {:ok, view, _html} = live(conn, ~p"/")

    assert view |> element("[data-testid=member-current-email]") |> render() =~ "ada@example.com"

    assert {:error, {:redirect, %{to: "https://checkout.stripe.com/c/pay/cs_test_member"}}} =
             view
             |> element("[data-testid=member-subscribe][data-product=pro-monthly]")
             |> render_click()

    assert_received {:stripe, "POST", "/v1/checkout/sessions", params}
    assert params["mode"] == "subscription"
    assert params["subscription_data"]["metadata"]["mishka_pay_owner"] == member.id
  end

  test "the post opens for a member with a plan that gives access, and closes when it ends",
       %{conn: conn} do
    {conn, member} = sign_in(conn, "grace@example.com")
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "[data-testid=members-post][data-open=false]")

    row = seed_subscription(member, :active, cancel_at_period_end: true)
    send(view.pid, {:mishka_pay, :subscription, %{record: row}})

    # The page hands the row to the part with send_update, a message of its own: this render
    # waits for the page to take the row, so the next one sees the part after it.
    render(view)
    assert has_element?(view, "[data-testid=members-post-text]")
    assert view |> element("[data-testid=member-sub-active]") |> render() =~ "yes"
    assert view |> element("[data-testid=member-sub-on-trial]") |> render() =~ "no"
    assert view |> element("[data-testid=member-sub-canceling]") |> render() =~ "yes"

    ended =
      row
      |> Ecto.Changeset.change(status: :canceled)
      |> Shop.Repo.update!()

    view |> element("[data-testid=members-post-check]") |> render_click()

    refute has_element?(view, "[data-testid=members-post-text]")
    assert view |> element("[data-testid=member-sub-active]") |> render() =~ "no"
    assert view |> element("[data-testid=member-sub-canceling]") |> render() =~ "no"
    assert ended.status == :canceled
  end

  test "another member's plan opens nothing, and a trial counts until it ends", %{conn: conn} do
    {_other_conn, other} = sign_in(build_conn(), "other@example.com")
    seed_subscription(other, :active)

    {conn, member} = sign_in(conn, "trial@example.com")
    seed_subscription(member, :trialing, trial_end: DateTime.add(DateTime.utc_now(), -60))
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "[data-testid=members-post-text]")
    assert view |> element("[data-testid=member-sub-on-trial]") |> render() =~ "no"

    seed_subscription(member, :trialing, trial_end: DateTime.add(DateTime.utc_now(), 86_400))
    view |> element("[data-testid=members-post-check]") |> render_click()

    assert has_element?(view, "[data-testid=members-post-text]")
  end

  test "signing out forgets the member", %{conn: conn} do
    {conn, _member} = sign_in(conn, "bye@example.com")
    conn = delete(conn, ~p"/member")
    {:ok, view, _html} = live(recycle(conn), ~p"/")

    assert has_element?(view, "[data-testid=member-sign-in-form]")
  end

  defp sign_in(conn, email) do
    conn = post(conn, ~p"/member", %{"email" => email})

    [member] =
      Ash.read!(Shop.Accounts.Member, authorize?: false) |> Enum.filter(&(&1.email == email))

    {recycle(conn), member}
  end

  defp seed_subscription(member, status, fields \\ []) do
    Ash.Seed.seed!(
      Shop.Pay.Subscription,
      Map.merge(
        %{
          provider: "stripe",
          provider_id: "sub_" <> String.slice(Ecto.UUID.generate(), 0, 8),
          tenant: "demo",
          status: status,
          plan: "Pro plan, monthly",
          user_id: member.id,
          synced_at: DateTime.utc_now()
        },
        Map.new(fields)
      )
    )
  end

  defp seed_plan do
    Ash.create!(
      Shop.Catalog.Product,
      %{
        slug: "pro-monthly",
        name: "Pro plan, monthly",
        price: "9.00",
        icon: "hero-bolt",
        interval: :month,
        tax_code: "txcd_10103001",
        position: 1
      },
      action: :seed,
      authorize?: false
    )
  end
end

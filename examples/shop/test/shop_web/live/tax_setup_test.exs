defmodule ShopWeb.TaxSetupTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  defp rate(id, active \\ true),
    do: %{
      "object" => "tax_rate",
      "id" => id,
      "display_name" => "VAT",
      "percentage" => 19.0,
      "inclusive" => true,
      "active" => active,
      "country" => "DE",
      "tax_type" => "vat",
      "metadata" => %{},
      "created" => 1_790_000_000
    }

  defp registration(id, extra \\ %{}),
    do:
      Map.merge(
        %{
          "object" => "tax.registration",
          "id" => id,
          "country" => "DE",
          "country_options" => %{"de" => %{"type" => "standard"}},
          "status" => "active",
          "active_from" => 1_790_000_000,
          "expires_at" => nil,
          "created" => 1_790_000_000
        },
        extra
      )

  defp settings(extra \\ %{}),
    do:
      Map.merge(
        %{
          "object" => "tax.settings",
          "defaults" => %{"tax_behavior" => nil, "tax_code" => "txcd_10000000"},
          "head_office" => nil,
          "status" => "pending",
          "status_details" => %{"pending" => %{"missing_fields" => ["head_office"]}}
        },
        extra
      )

  setup do
    test = self()

    StripeStub.stub(fn
      "GET", "/v1/tax_rates", _params ->
        send(test, :rates_read)
        StripeStub.list([rate("txr_1")])

      "POST", "/v1/tax_rates", params ->
        send(test, {:rate_made, params})
        rate("txr_new")

      "POST", "/v1/tax_rates/txr_1", params ->
        send(test, {:rate_changed, params})
        rate("txr_1", false)

      "GET", "/v1/tax/registrations", _params ->
        StripeStub.list([registration("taxreg_1")])

      "POST", "/v1/tax/registrations", %{"country" => "US"} = params ->
        send(test, {:registered, params})

        registration("taxreg_us", %{
          "country" => "US",
          "country_options" => %{"us" => %{"type" => "state_sales_tax", "state" => "CA"}}
        })

      "POST", "/v1/tax/registrations/taxreg_1", params ->
        send(test, {:registration_ended, params})
        registration("taxreg_1", %{"expires_at" => 1_790_000_100, "status" => "expired"})

      "GET", "/v1/tax/settings", _params ->
        settings()

      "POST", "/v1/tax/settings", params ->
        send(test, {:settings_saved, params})

        settings(%{
          "head_office" => %{"address" => %{"country" => "DE", "postal_code" => "10115"}},
          "status" => "active",
          "status_details" => %{"active" => %{}}
        })

      _method, _path, _params ->
        nil
    end)

    :ok
  end

  defp shown(conn) do
    {:ok, view, _html} = live(conn, "/")
    refute_received :rates_read
    refute has_element?(view, "[data-testid=tax-rate-rows]")

    view |> element("[data-testid=tax-setup-show]") |> render_click()
    render_async(view)
    assert_received :rates_read
    view
  end

  test "nothing is read until shown; then rates, registrations and settings show", %{conn: conn} do
    view = shown(conn)

    assert has_element?(view, "[data-rate-id=txr_1] [data-testid=tax-rate-percent]", "19")
    assert has_element?(view, "[data-registration-id=taxreg_1]", "standard")
    assert has_element?(view, "[data-testid=tax-settings-status]", "head_office")
  end

  test "a rate is made, and one archived", %{conn: conn} do
    view = shown(conn)

    view
    |> form("[data-testid=tax-rate-form]", %{
      display_name: "Sales tax",
      percentage: "7.25",
      inclusive: "false",
      country: "US",
      tax_type: "sales_tax"
    })
    |> render_submit()

    assert_received {:rate_made, made}

    assert %{"percentage" => "7.25", "inclusive" => "false", "country" => "US"} = made
    assert has_element?(view, "[data-testid=tax-rate-row][data-rate-id=txr_new]")
    assert has_element?(view, "[data-testid=tax-setup-notice]", "txr_new")

    view |> element("[data-rate-id=txr_1] [data-testid=tax-rate-archive]") |> render_click()

    assert_received {:rate_changed, %{"active" => "false"}}
    assert has_element?(view, "[data-rate-id=txr_1] [data-testid=tax-rate-active]", "no")
    refute has_element?(view, "[data-rate-id=txr_1] [data-testid=tax-rate-archive]")
  end

  test "a rate that cannot be right says so, and nothing is sent", %{conn: conn} do
    view = shown(conn)

    view
    |> form("[data-testid=tax-rate-form]", %{percentage: "150"})
    |> render_submit()

    refute_received {:rate_made, _params}
    assert has_element?(view, "[data-testid=tax-setup-error]", "percentage")
    assert has_element?(view, "[data-testid=tax-rate-percentage][value='150']")
  end

  test "a US registration needs its state; with it, it is added; one is ended", %{conn: conn} do
    view = shown(conn)

    view
    |> form("[data-testid=tax-registration-form]", %{country: "US", type: "state_sales_tax"})
    |> render_submit()

    refute_received {:registered, _params}
    assert has_element?(view, "[data-testid=tax-setup-error]", "state")

    view
    |> form("[data-testid=tax-registration-form]", %{
      country: "US",
      type: "state_sales_tax",
      state: "ca"
    })
    |> render_submit()

    assert_received {:registered, %{"country_options" => %{"us" => %{"state" => "CA"}}}}

    assert has_element?(
             view,
             "[data-testid=tax-registration-row][data-registration-id=taxreg_us]"
           )

    view
    |> element("[data-registration-id=taxreg_1] [data-testid=tax-registration-end]")
    |> render_click()

    assert_received {:registration_ended, %{"expires_at" => "now"}}

    assert has_element?(
             view,
             "[data-registration-id=taxreg_1] [data-testid=tax-registration-status]",
             "expired"
           )
  end

  test "the settings are saved: the head office and the default behavior", %{conn: conn} do
    view = shown(conn)

    view
    |> form("[data-testid=tax-settings-form]", %{
      country: "de",
      postal_code: "10115",
      tax_behavior: "exclusive"
    })
    |> render_submit()

    assert_received {:settings_saved, saved}

    assert %{
             "head_office" => %{"address" => %{"country" => "DE", "postal_code" => "10115"}},
             "defaults" => %{"tax_behavior" => "exclusive", "tax_code" => "txcd_10000000"}
           } = saved

    assert has_element?(view, "[data-testid=tax-settings-status]", "active")
  end
end

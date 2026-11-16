defmodule ShopWeb.EntitlementsTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  @feature %{
    "id" => "feat_1",
    "object" => "entitlements.feature",
    "name" => "Pro reports",
    "lookup_key" => "pro-reports",
    "active" => true
  }

  test "makes a feature, attaches it to a product, and lists a customer's entitlements", %{
    conn: conn
  } do
    StripeStub.stub(fn
      "POST", "/v1/entitlements/features", %{"lookup_key" => "pro-reports"} ->
        @feature

      "POST", "/v1/products/prod_1/features", %{"entitlement_feature" => "feat_1"} ->
        %{"object" => "product_feature", "entitlement_feature" => @feature}

      "GET", "/v1/entitlements/active_entitlements", %{"customer" => "cus_1"} ->
        StripeStub.list([
          %{"id" => "ent_1", "feature" => "feat_1", "lookup_key" => "pro-reports"}
        ])

      _method, _path, _params ->
        nil
    end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("[data-testid=feature-form]", %{name: "Pro reports", lookup_key: "pro-reports"})
    |> render_submit()

    assert has_element?(view, "[data-testid=feature-row][data-feature-id=feat_1]")

    view
    |> form("[data-testid=feature-attach-form]", %{product_id: "prod_1", feature_id: "feat_1"})
    |> render_submit()

    assert has_element?(
             view,
             "[data-testid=entitlements-notice]",
             "pro-reports comes with prod_1"
           )

    view
    |> form("[data-testid=entitlements-form]", %{customer_id: "cus_1"})
    |> render_submit()

    assert has_element?(view, "[data-testid=entitlement-row][data-lookup-key=pro-reports]")
  end

  test "refuses a feature id that is not one", %{conn: conn} do
    StripeStub.stub(fn _method, _path, _params -> nil end)
    {:ok, view, _html} = live(conn, "/")

    view
    |> form("[data-testid=feature-attach-form]", %{product_id: "prod_1", feature_id: "nope"})
    |> render_submit()

    assert has_element?(view, "[data-testid=entitlements-error]")
  end
end

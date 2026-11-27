defmodule ShopWeb.DiscountsTest do
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeRoutes

  test "a coupon made for some products sends them to Stripe as applies_to and says so",
       %{conn: conn} do
    StripeRoutes.stub(%{
      {"POST", "/v1/coupons"} => fn params ->
        %{
          "object" => "coupon",
          "id" => "SPRING",
          "name" => "Spring sale",
          "percent_off" => 20,
          "duration" => "once",
          "valid" => true,
          "times_redeemed" => 0,
          "applies_to" => %{"products" => Map.values(params["applies_to"]["products"])}
        }
      end
    })

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=new-coupon-toggle]") |> render_click()

    view
    |> form("[data-testid=new-coupon-form]", %{
      name: "Spring sale",
      coupon_id: "SPRING",
      percent_off: "20",
      duration: "once",
      product_ids: "prod_ebook, prod_hoodie"
    })
    |> render_submit()

    assert_received {:stripe, "POST", "/v1/coupons", params}

    assert params["applies_to"]["products"] |> Map.values() |> Enum.sort() ==
             ["prod_ebook", "prod_hoodie"]

    assert params["expand"] |> Map.values() == ["applies_to"]
    assert view |> element("#flash-info") |> render() =~ "only for prod_ebook, prod_hoodie"
  end

  test "the coupons list names the products a coupon is for, read back from Stripe", %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/coupons"} => %{
        "object" => "list",
        "has_more" => false,
        "data" => [
          %{
            "object" => "coupon",
            "id" => "SPRING",
            "percent_off" => 20,
            "duration" => "once",
            "valid" => true,
            "times_redeemed" => 0,
            "applies_to" => %{"products" => ["prod_ebook", "prod_hoodie"]}
          },
          %{
            "object" => "coupon",
            "id" => "ALL",
            "percent_off" => 10,
            "duration" => "once",
            "valid" => true,
            "times_redeemed" => 0
          }
        ]
      }
    })

    {:ok, view, _html} = live(conn, ~p"/")

    assert_received {:stripe, "GET", "/v1/coupons", %{"expand" => ["data.applies_to"]}}

    assert view
           |> element("[data-coupon-id=SPRING] [data-testid=coupon-row-products]")
           |> render() =~ "only for prod_ebook, prod_hoodie"

    refute has_element?(view, "[data-coupon-id=ALL] [data-testid=coupon-row-products]")
  end

  test "a coupon with no products typed is for every product and sends none", %{conn: conn} do
    StripeRoutes.stub(%{
      {"POST", "/v1/coupons"} => %{
        "object" => "coupon",
        "id" => "ALL",
        "amount_off" => 500,
        "currency" => "usd",
        "duration" => "once",
        "valid" => true
      }
    })

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-testid=new-coupon-toggle]") |> render_click()

    view
    |> form("[data-testid=new-coupon-form]", %{amount_off: "5.00", duration: "once"})
    |> render_submit()

    assert_received {:stripe, "POST", "/v1/coupons", params}
    refute Map.has_key?(params, "applies_to")
    assert view |> element("#flash-info") |> render() =~ "for every product"
  end

  test "a checkout read back names the discounts it applied, a code the buyer typed included",
       %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/checkout/sessions/cs_test_coded"} => %{
        "object" => "checkout.session",
        "id" => "cs_test_coded",
        "status" => "complete",
        "currency" => "usd",
        "amount_total" => 3120,
        "total_details" => %{"amount_discount" => 780, "amount_tax" => 0},
        "discounts" => [
          %{"coupon" => "SPRING", "promotion_code" => %{"id" => "promo_box"}},
          %{"coupon" => %{"id" => "LOYAL"}, "promotion_code" => nil}
        ]
      }
    })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=read-checkout-form]", checkout_id: "cs_test_coded")
    |> render_submit()

    assert has_element?(view, "[data-testid=checkout-applied]", "code promo_box (coupon SPRING)")
    assert has_element?(view, "[data-testid=checkout-applied]", "coupon LOYAL")
    assert has_element?(view, "[data-testid=checkout-discount]", "7.80")
  end

  test "a checkout that applied nothing shows no discounts", %{conn: conn} do
    StripeRoutes.stub(%{
      {"GET", "/v1/checkout/sessions/cs_test_plain"} => %{
        "object" => "checkout.session",
        "id" => "cs_test_plain",
        "status" => "open",
        "currency" => "usd"
      }
    })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("[data-testid=read-checkout-form]", checkout_id: "cs_test_plain")
    |> render_submit()

    assert has_element?(view, "[data-testid=checkout-card]")
    refute has_element?(view, "[data-testid=checkout-discounts]")
  end
end

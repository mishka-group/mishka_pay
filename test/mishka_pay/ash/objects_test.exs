# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Ash.ObjectsTest do
  # Starts plugins and shares the sandboxed database with their tasks; Stripe answers through
  # Stripe's own mock server, which checks every request against Stripe's spec.
  use MishkaPay.DataCase, async: false

  alias MishkaPay.Providers.Stripe

  alias MishkaPay.Support.{
    SiteCoupon,
    SiteInvoice,
    SitePaymentLink,
    SitePrice,
    SiteProduct,
    SitePromotionCode,
    StripeMock
  }

  @moduletag :stripe_mock

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_a"}, "site-a")
    MishkaPay.Test.stub_http(&StripeMock.forward/1)
    :ok
  end

  defp run(resource, action, args, tenant \\ "site-a") do
    resource
    |> Ash.Changeset.for_create(action, Map.put(args, :provider, "stripe"), tenant: tenant)
    |> Ash.create(authorize?: false)
  end

  defp act(row, action, args \\ %{}),
    do: row |> Ash.Changeset.for_update(action, args) |> Ash.update(authorize?: false)

  test "each kind syncs its object into the site that asked, once per object" do
    for {resource, id_argument, id} <- [
          {SiteProduct, :product_id, "prod_1"},
          {SitePrice, :price_id, "price_1"},
          {SiteCoupon, :coupon_id, "co_1"},
          {SitePromotionCode, :promotion_code_id, "promo_1"},
          {SitePaymentLink, :payment_link_id, "plink_1"},
          {SiteInvoice, :invoice_id, "in_1"}
        ] do
      assert {:ok, first} = run(resource, :sync, %{id_argument => id})
      assert {:ok, again} = run(resource, :sync, %{id_argument => id})
      assert {first.id, first.site_id, first.tenant} == {again.id, "site-a", "site-a"}
      assert [_one] = Ash.read!(resource, tenant: "site-a", authorize?: false)
      assert [] = Ash.read!(resource, tenant: "site-b", authorize?: false)
    end
  end

  test "a site's admin makes, changes and archives its catalog, coupons and codes at the provider" do
    assert {:ok, product} = run(SiteProduct, :add, %{name: "Ebook", tax_code: "txcd_10302000"})
    assert {:ok, %{synced_at: %DateTime{}}} = act(product, :edit, %{name: "Ebook 2"})
    assert {:ok, %{}} = act(product, :archive)

    assert {:ok, price} =
             run(SitePrice, :add, %{
               product_id: "prod_1",
               amount: %{amount: "12.00", currency: "USD"}
             })

    assert %{money: %Money{}} = Ash.load!(price, :money, tenant: "site-a")
    assert {:ok, %{}} = act(price, :archive)

    assert {:ok, coupon} = run(SiteCoupon, :add, %{percent_off: Decimal.new(10), duration: :once})
    assert {:ok, %{deleted_at: %DateTime{}}} = act(coupon, :remove)

    assert {:ok, code} = run(SitePromotionCode, :add, %{coupon_id: "co_1", code: "SAVE10"})
    assert {:ok, %{}} = act(code, :edit, %{active: false})
  end

  test "a site's admin sells with a payment link and bills by hand, step by step" do
    assert {:ok, link} =
             run(SitePaymentLink, :add, %{link: %{items: [%{id: "price_1", quantity: 1}]}})

    assert {:ok, %{}} = act(link, :edit, %{changes: %{active: false}})

    draft = %{
      customer_id: "cus_1",
      collection: :send_invoice,
      items: [%{name: "Setup", amount: %{amount: "90", currency: "USD"}}]
    }

    assert {:ok, bill} = run(SiteInvoice, :add, %{draft: draft})
    assert %{money: %Money{}} = Ash.load!(bill, :money, tenant: "site-a")

    for step <- [:finalize, :send, :void, :mark_uncollectible],
        do: assert({:ok, %{}} = act(bill, step))

    assert {:ok, %{}} = act(bill, :pay, %{out_of_band: true})
    assert {:ok, %{deleted_at: %DateTime{}}} = act(bill, :remove)
  end

  test "a webhook about a product syncs it into the site's resource; other objects are left" do
    MishkaPay.Test.start_plugin!(SiteProduct.MishkaPayListener)

    event = %MishkaPay.Event{
      provider: "stripe",
      tenant: "site-a",
      id: "evt_1",
      type: "product.updated",
      object_type: "product",
      object_id: "prod_1"
    }

    assert %{failed: nil} =
             MishkaInstaller.Event.Hook.call(
               MishkaPay.Events.event_process(),
               %{event: event, failed: nil}
             )

    assert [%{provider_id: "prod_" <> _}] =
             Ash.read!(SiteProduct, tenant: "site-a", authorize?: false)

    other = %{
      event
      | id: "evt_2",
        type: "price.updated",
        object_type: "price",
        object_id: "price_1"
    }

    assert %{failed: nil} =
             MishkaInstaller.Event.Hook.call(
               MishkaPay.Events.event_process(),
               %{event: other, failed: nil}
             )

    assert [_still_one] = Ash.read!(SiteProduct, tenant: "site-a", authorize?: false)
  end

  test "an event about a product from a provider with no catalog is left alone, never retried" do
    MishkaPay.Test.start_plugin!(MishkaPay.Providers.PayPal)
    MishkaPay.Test.start_plugin!(SiteProduct.MishkaPayListener)

    event = %MishkaPay.Event{
      provider: "paypal",
      tenant: "site-a",
      id: "WH-1",
      type: "CATALOG.PRODUCT.CREATED",
      object_type: "product",
      object_id: "PROD-1"
    }

    assert %{failed: nil} =
             MishkaInstaller.Event.Hook.call(
               MishkaPay.Events.event_process(),
               %{event: event, failed: nil}
             )

    assert [] = Ash.read!(SiteProduct, tenant: "site-a", authorize?: false)
  end
end

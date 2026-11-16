# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Ash.MultitenancyTest do
  # Starts plugins and shares the sandboxed database with their tasks; Stripe answers through
  # Stripe's own mock server.
  use MishkaPay.DataCase, async: false

  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Support.{Inbox, SitePayment, SitePaymentSync, StripeMock}

  @moduletag :stripe_mock

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_a", webhook_secret: "whsec_sites"})
    MishkaPay.Test.stub_http(&StripeMock.forward/1)
    :ok
  end

  test "a sync in a site's Ash tenant reads that site's keys and keeps the row in that site" do
    assert {:ok, row} =
             Ash.create(SitePayment, %{provider: "stripe", payment_id: "pi_123"},
               action: :sync,
               tenant: "site-a",
               authorize?: false
             )

    assert {row.tenant, row.site_id} == {"site-a", "site-a"}
    assert [_one] = Ash.read!(SitePayment, tenant: "site-a", authorize?: false)
    assert [] = Ash.read!(SitePayment, tenant: "site-b", authorize?: false)
  end

  test "a webhook syncs its row inside the site its URL names, and only there" do
    MishkaPay.Test.start_plugin!(Inbox)
    MishkaPay.Test.start_plugin!(SitePaymentSync)

    for site <- ["site-a", "site-b"] do
      conn =
        MishkaPay.Test.deliver_event(
          site,
          "payment_intent.succeeded",
          MishkaPay.Test.stripe_object(:payment_intent, %{"id" => "pi_123"}),
          "whsec_sites",
          id: "evt_#{site}"
        )

      assert conn.status == 200
    end

    Oban.drain_queue(queue: :mishka_pay_inbox)

    assert [%{site_id: "site-a", tenant: "site-a"}] =
             Ash.read!(SitePayment, tenant: "site-a", authorize?: false)

    assert [%{site_id: "site-b", tenant: "site-b"}] =
             Ash.read!(SitePayment, tenant: "site-b", authorize?: false)
  end
end

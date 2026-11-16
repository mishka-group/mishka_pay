# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Ash.CustomerTest do
  # Starts plugins and shares the sandboxed database with their tasks.
  use MishkaPay.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias MishkaPay.{Customer, PortalSession, Webhook}
  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Support.{Acme, CustomerWatcher, StripeMock}
  alias MishkaPay.Support.Customer.MishkaPayListener, as: CustomerSync
  alias MishkaPay.Support.WebhookEvent.MishkaPayListener, as: Inbox

  @customer MishkaPay.Support.Customer
  @event "test/fixtures/stripe/event.json" |> File.read!() |> JSON.decode!()
  @secret "whsec_test_site_a"

  setup do
    MishkaPay.Test.start_plugin!(Acme)
    MishkaPay.Test.put_keys("acme", %{secret_key: "sk_acme"})
    :ok
  end

  defp register(attrs \\ %{}) do
    Ash.create(
      @customer,
      Map.merge(
        %{
          provider: "acme",
          tenant: "site-a",
          email: "ava@example.com",
          name: "Ava",
          reference: "user-1",
          metadata: %{plan: "pro"}
        },
        attrs
      ),
      action: :register,
      authorize?: false
    )
  end

  test "register makes the customer at the provider, keeps one row for it and announces it" do
    MishkaPay.Test.start_plugin!(CustomerWatcher)

    assert {:ok, first} = register()
    assert {:ok, again} = register()

    assert again.id == first.id
    assert %{provider_id: "acme_cus_1", tenant: "site-a", reference: "user-1"} = first
    assert first.metadata == %{"plan" => "pro"}
    assert [_one] = Ash.read!(@customer, authorize?: false)
    assert_received {:customer_changed, %Customer{id: "acme_cus_1"}, %{id: id}}
    assert id == first.id
  end

  test "register for a person the site has already reads them again instead of making a second customer" do
    test_pid = self()

    :telemetry.attach_many(
      "register-test",
      [[:mishka_pay, :customer_create, :stop], [:mishka_pay, :customer, :stop]],
      fn [_, operation, _], _measurements, _meta, _config ->
        send(test_pid, {:called, operation})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("register-test") end)

    assert {:ok, first} = register()
    assert_received {:called, :customer_create}

    assert {:ok, again} = register()
    assert again.id == first.id
    assert_received {:called, :customer}
    refute_received {:called, :customer_create}
  end

  test "edit sends the change to the provider and writes its answer" do
    {:ok, row} = register()
    MishkaPay.Test.start_plugin!(CustomerWatcher)

    assert {:ok, edited} =
             row
             |> Ash.Changeset.for_update(:edit, %{name: "Ava M.", phone: "+15550100"})
             |> Ash.update(authorize?: false)

    assert {edited.id, edited.name, edited.phone} == {row.id, "Ava M.", "+15550100"}
    assert_received {:customer_changed, %Customer{name: "Ava M."}, _record}
  end

  test "a customer the provider cannot make or give is an error, and nothing is written" do
    assert {:error, %Ash.Error.Invalid{}} = register(%{email: "not an email"})
    assert {:error, _unknown} = register(%{provider: "nope"})
    assert [] = Ash.read!(@customer, authorize?: false)
  end

  test "a sync keeps a customer the provider deleted, marked deleted" do
    {:ok, row} = sync("acme_cus_1")
    assert row.deleted_at == nil
    assert row.email == "ava@example.com"

    assert {:ok, gone} = sync("acme_cus_gone")
    assert gone.deleted_at
  end

  test "portal opens the provider's portal for the row, and refuses an unsafe return URL" do
    {:ok, row} = register()

    assert {:ok, %PortalSession{url: "https://pay.acme.test/portal/acme_cus_1"}} =
             portal(row.id, "https://shop.test/account")

    assert {:error, %Ash.Error.Invalid{}} = portal(row.id, "http://evil.test/back")
    assert {:error, _not_found} = portal(Ash.UUIDv7.generate(), "https://shop.test/account")
  end

  @tag :stripe_mock
  test "a Stripe webhook about a customer reaches its row through the inbox" do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_a", webhook_secret: @secret})
    MishkaPay.Test.stub_http(&StripeMock.forward/1)
    MishkaPay.Test.start_plugin!(Inbox)
    MishkaPay.Test.start_plugin!(CustomerSync)

    assert deliver(%{"id" => "evt_customer", "type" => "customer.updated"}, %{
             "id" => "cus_123",
             "object" => "customer"
           }) == 200

    Oban.drain_queue(queue: :mishka_pay_inbox)

    assert [%{provider: "stripe", provider_id: "cus_123", tenant: "site-a"}] =
             Ash.read!(@customer, authorize?: false)

    # A card taken off names the customer it left only in `previous_attributes`.
    detached = %{
      "id" => "evt_card",
      "type" => "payment_method.detached",
      "data" => %{"previous_attributes" => %{"customer" => "cus_456"}}
    }

    assert deliver(detached, %{"id" => "pm_1", "object" => "payment_method", "customer" => nil}) ==
             200

    Oban.drain_queue(queue: :mishka_pay_inbox)

    assert ["cus_123", "cus_456"] =
             @customer
             |> Ash.read!(authorize?: false)
             |> Enum.map(& &1.provider_id)
             |> Enum.sort()
  end

  # A signed Stripe webhook about `object`, as Stripe posts it.
  defp deliver(changes, object) do
    body =
      @event
      |> Map.merge(Map.delete(changes, "data"))
      |> Map.update!("data", &Map.merge(&1, Map.get(changes, "data", %{})))
      |> put_in(["data", "object"], object)
      |> JSON.encode!()

    time = System.system_time(:second)

    conn =
      conn(:post, "/pay/webhooks/stripe/site-a", body)
      |> put_req_header(
        "stripe-signature",
        "t=#{time},v1=#{Stripe.signature(body, time, @secret)}"
      )
      |> Webhook.call(Webhook.init(at: "/pay/webhooks"))

    conn.status
  end

  defp sync(id) do
    Ash.create(@customer, %{provider: "acme", customer_id: id, tenant: "site-a"},
      action: :sync,
      authorize?: false
    )
  end

  defp portal(id, return_url) do
    @customer
    |> Ash.ActionInput.for_action(:portal, %{id: id, return_url: return_url})
    |> Ash.run_action(authorize?: false)
  end
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Ash.PaymentTest do
  # Starts plugins and shares the sandboxed database with their tasks; Stripe answers through
  # Stripe's own mock server.
  use MishkaPay.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias MishkaPay.{Payment, Webhook}
  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Support.{Inbox, PaymentSync, PaymentWatcher, StripeMock}

  @moduletag :stripe_mock

  @payment MishkaPay.Support.Payment
  @event "test/fixtures/stripe/event.json" |> File.read!() |> JSON.decode!()
  @secret "whsec_test_site_a"

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_a", webhook_secret: @secret})
    MishkaPay.Test.stub_http(&StripeMock.forward/1)
    :ok
  end

  defp sync(attrs \\ %{}) do
    Ash.create(
      @payment,
      Map.merge(%{provider: "stripe", payment_id: "pi_123", tenant: "site-a"}, attrs),
      action: :sync,
      authorize?: false
    )
  end

  test "a sync reads the payment from Stripe and keeps it, with its money" do
    assert {:ok, payment} = sync()

    assert payment.provider == "stripe"
    assert payment.provider_id == "pi_123"
    assert payment.tenant == "site-a"
    assert payment.currency == "USD"
    assert Decimal.equal?(payment.amount, "10.99")

    assert %{money: money, money_refunded: refunded} =
             Ash.load!(payment, [:money, :money_refunded])

    assert money == Money.new(:USD, "10.99")
    assert Money.zero?(refunded)
  end

  test "syncing the same payment again updates the one row it has" do
    {:ok, first} = sync()
    {:ok, again} = sync()

    assert again.id == first.id
    assert DateTime.compare(again.synced_at, first.synced_at) in [:gt, :eq]
    assert [_one] = Ash.read!(@payment, authorize?: false)
  end

  test "a payment Stripe cannot give is an error and nothing is written" do
    MishkaPay.Test.put_keys("stripe", %{secret_key: "not-a-key"})

    assert {:error, _error} = sync()
    assert [] = Ash.read!(@payment, authorize?: false)
  end

  test "a sync announces the change to the host" do
    MishkaPay.Test.start_plugin!(PaymentWatcher)
    {:ok, record} = sync()

    assert_received {:payment_changed, %Payment{id: "pi_123"}, %{id: id}}
    assert id == record.id
  end

  test "a webhook about a payment reaches the payment row through the inbox" do
    MishkaPay.Test.start_plugin!(Inbox)
    MishkaPay.Test.start_plugin!(PaymentSync)

    body =
      @event
      |> Map.merge(%{"id" => "evt_pi", "type" => "payment_intent.succeeded"})
      |> put_in(["data", "object"], %{"id" => "pi_123", "object" => "payment_intent"})
      |> JSON.encode!()

    time = System.system_time(:second)

    conn =
      conn(:post, "/pay/webhooks/stripe", body)
      |> put_req_header(
        "stripe-signature",
        "t=#{time},v1=#{Stripe.signature(body, time, @secret)}"
      )
      |> Webhook.call(Webhook.init(at: "/pay/webhooks"))

    assert conn.status == 200
    assert [] = Ash.read!(@payment, authorize?: false)

    Oban.drain_queue(queue: :mishka_pay_inbox)

    assert [%{provider_id: "pi_123", status: :failed}] = Ash.read!(@payment, authorize?: false)
  end

  describe "actions" do
    test ":start_checkout answers the provider's page, and a bad checkout an Ash error on its field" do
      checkout = %{
        provider: "stripe",
        items: [%{name: "Ebook", amount: %{amount: "19.99", currency: "USD"}}],
        success_url: "https://shop.test/thanks",
        cancel_url: "https://shop.test/cart"
      }

      assert {:ok, %MishkaPay.Checkout{url: "https://checkout.stripe.com/" <> _}} =
               @payment
               |> Ash.ActionInput.for_action(:start_checkout, %{checkout: checkout})
               |> Ash.run_action(authorize?: false)

      assert {:error,
              %Ash.Error.Invalid{
                errors: [%Ash.Error.Changes.InvalidArgument{field: :success_url}]
              }} =
               @payment
               |> Ash.ActionInput.for_action(:start_checkout, %{
                 checkout: %{checkout | success_url: "http://x.test"}
               })
               |> Ash.run_action(authorize?: false)
    end

    test ":refund refunds through Stripe, syncs the row and keeps the refund" do
      {:ok, payment} = sync()

      assert {:ok, refunded} =
               payment
               |> Ash.Changeset.for_update(:refund, %{
                 amount: %{amount: "5", currency: "USD"},
                 reason: :requested_by_customer
               })
               |> Ash.update(authorize?: false)

      assert %MishkaPay.Refund{status: :succeeded, payment_id: "pi_123"} =
               refunded.__metadata__.refund

      assert DateTime.compare(refunded.synced_at, payment.synced_at) in [:gt, :eq]
    end

    test ":refund in another currency or over what is left is an Ash error on the amount" do
      {:ok, payment} = sync()

      for amount <- [%{amount: "5", currency: "EUR"}, %{amount: "11", currency: "USD"}] do
        assert {:error,
                %Ash.Error.Invalid{errors: [%Ash.Error.Changes.InvalidArgument{field: :amount}]}} =
                 payment
                 |> Ash.Changeset.for_update(:refund, %{amount: amount})
                 |> Ash.update(authorize?: false)
      end
    end
  end
end

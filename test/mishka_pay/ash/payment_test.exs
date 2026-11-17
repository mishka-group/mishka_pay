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
  alias MishkaPay.Support.Payment.MishkaPayListener, as: PaymentSync
  alias MishkaPay.Support.{PaymentWatcher, StripeMock}
  alias MishkaPay.Support.WebhookEvent.MishkaPayListener, as: Inbox

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

  describe "safety" do
    test "a site that refunds many times needs a reference on each refund, as an Ash error" do
      {:ok, payment} = sync()
      MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_a", refunds: "many"})

      assert {:error,
              %Ash.Error.Invalid{
                errors: [%Ash.Error.Changes.InvalidArgument{field: :reference}]
              }} =
               payment |> Ash.Changeset.for_update(:refund, %{}) |> Ash.update(authorize?: false)

      assert {:ok, %{__metadata__: %{refund: %MishkaPay.Refund{reference: "refund-4"}}}} =
               payment
               |> Ash.Changeset.for_update(:refund, %{reference: "refund-4"})
               |> Ash.update(authorize?: false)
    end

    test "a refund that went through still succeeds when the payment cannot be read again" do
      {:ok, payment} = sync()
      MishkaPay.Test.start_plugin!(PaymentWatcher)

      # Stripe answers the read before the refund and the refund itself, then goes down.
      MishkaPay.Test.stub_http(fn conn ->
        case Process.get(:refunded) do
          true ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"error" => %{"message" => "down"}})

          nil ->
            if conn.method == "POST", do: Process.put(:refunded, true)
            StripeMock.forward(conn)
        end
      end)

      assert {:ok, refunded} =
               payment
               |> Ash.Changeset.for_update(:refund, %{
                 amount: %{amount: "5", currency: "USD"}
               })
               |> Ash.update(authorize?: false)

      assert %MishkaPay.Refund{status: :succeeded} = refunded.__metadata__.refund
      assert refunded.status == :partially_refunded
      refute_received {:payment_changed, _payment, _record}
      assert Decimal.equal?(refunded.amount_refunded, "5")
    end

    test "a later sync never moves a payment to another tenant" do
      {:ok, first} = sync(%{tenant: "site-a"})
      {:ok, again} = sync(%{tenant: "site-b"})

      assert again.id == first.id
      assert again.tenant == "site-a"
    end

    test "a refund of less than zero says it must be more than zero, as zero does" do
      {:ok, payment} = sync()

      for amount <- ["-5", "0"] do
        assert {:error, %Ash.Error.Invalid{} = error} =
                 payment
                 |> Ash.Changeset.for_update(:refund, %{
                   amount: %{amount: amount, currency: "USD"}
                 })
                 |> Ash.update(authorize?: false)

        assert MishkaPay.Ash.message(error) =~ "more than zero"
      end
    end

    test "a nested input's error reaches Ash at its inner field, and no message carries breadcrumbs" do
      checkout = %{
        provider: "stripe",
        items: [%{name: "Ebook", amount: %{amount: "19.99", currency: "USD"}}],
        success_url: "https://shop.test/thanks",
        cancel_url: "https://shop.test/cart",
        customer: %{email: "not-an-email"}
      }

      assert {:error,
              %Ash.Error.Invalid{errors: [%Ash.Error.Changes.InvalidArgument{} = inner]} = error} =
               @payment
               |> Ash.ActionInput.for_action(:start_checkout, %{checkout: checkout})
               |> Ash.run_action(authorize?: false)

      assert inner.field == :email
      refute MishkaPay.Ash.message(error) =~ "customer field"

      assert {:error, required} =
               Ash.create(@payment, %{provider: "stripe"}, action: :sync, authorize?: false)

      refute MishkaPay.Ash.message(required) =~ "Bread Crumbs"
      assert MishkaPay.Ash.message(required) =~ "payment_id"
    end

    test "several errors read as separate sentences" do
      assert {:error, %MishkaPay.Errors.Invalid{errors: [_, _ | _]} = error} =
               MishkaPay.create_tax_registration(%{provider: "acme", country: "D", type: "-"})

      text = MishkaPay.Ash.message(error)
      refute text =~ ";"
      refute text =~ ".."
      assert [_, _ | _] = String.split(text, ". ")
    end

    test "errors reach Ash as plain words, with no stack trace" do
      declined = MishkaPay.Errors.Declined.exception(provider: "stripe", reason: "card_declined")

      assert [
               %Ash.Error.Unknown.UnknownError{
                 error: "stripe declined the payment: card_declined"
               }
             ] =
               MishkaPay.Ash.to_ash_error(declined)

      refused = MishkaPay.Errors.Refused.exception(operation: :checkout, reason: "closed")

      assert [%Ash.Error.Changes.InvalidChanges{message: "the checkout was refused: closed"}] =
               MishkaPay.Ash.to_ash_error(refused)

      unsupported = MishkaPay.Errors.Unsupported.exception(provider: "acme", operation: "pausing")

      assert [%Ash.Error.Changes.InvalidChanges{message: "Acme does not support pausing"}] =
               MishkaPay.Ash.to_ash_error(unsupported)

      for error <- [declined, refused, unsupported] do
        text =
          error
          |> MishkaPay.Ash.to_ash_error()
          |> Ash.Error.to_error_class()
          |> Exception.message()

        refute text =~ ".ex:"
      end
    end
  end

  test "an admin page reads a payment row's refunds from its provider" do
    {:ok, row} = sync()

    assert {:ok, [%MishkaPay.Refund{} | _]} =
             @payment
             |> Ash.ActionInput.for_action(:refunds, %{id: row.id})
             |> Ash.run_action(authorize?: false)
  end

  test "a held payment captured in part keeps what was taken beside what was asked" do
    MishkaPay.Test.stub_http(fn
      %{request_path: "/v1/checkout/sessions"} = conn ->
        Req.Test.json(conn, %{"object" => "list", "data" => [], "has_more" => false})

      conn ->
        Req.Test.json(conn, %{
          "id" => "pi_held",
          "object" => "payment_intent",
          "amount" => 2000,
          "amount_received" => 1250,
          "currency" => "usd",
          "status" => "succeeded",
          "latest_charge" => %{
            "amount_captured" => 1250,
            "amount_refunded" => 0,
            "refunds" => %{"data" => []}
          },
          "metadata" => %{}
        })
    end)

    {:ok, row} = sync(%{payment_id: "pi_held"})
    row = Ash.load!(row, [:money, :money_captured])
    assert Money.equal?(row.money, Money.new(:USD, "20.00"))
    assert Money.equal?(row.money_captured, Money.new(:USD, "12.50"))
  end
end

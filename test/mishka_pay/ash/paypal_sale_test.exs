# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Ash.PayPalSaleTest do
  # A one-time sale through PayPal, end to end the way an extension takes one through Stripe:
  # checkout, the buyer's return, the webhook into the inbox, the payment row, a refund and its
  # webhook. PayPal answers through the test kit's stand-in.
  use MishkaPay.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias MishkaPay.Helpers.TokenCache
  alias MishkaPay.Providers.PayPal
  alias MishkaPay.Support.Payment.MishkaPayListener, as: PaymentSync
  alias MishkaPay.Support.WebhookEvent.MishkaPayAnswerListener, as: InboxAnswer
  alias MishkaPay.Support.WebhookEvent.MishkaPayListener, as: Inbox
  alias MishkaPay.Test.PayPal, as: PayPalStub
  alias MishkaPay.Webhook

  @payment MishkaPay.Support.Payment
  @inbox MishkaPay.Support.WebhookEvent

  setup do
    MishkaPay.Test.start_plugin!(PayPal)

    MishkaPay.Test.put_keys(
      "paypal",
      %{publishable_key: "client_s", secret_key: "secret_s", webhook_secret: "WH-1", mode: :test},
      "site-a"
    )

    PayPalStub.stub!()
    TokenCache.drop({:paypal, "client_s", :test})

    for plugin <- [Inbox, InboxAnswer, PaymentSync], do: MishkaPay.Test.start_plugin!(plugin)
    :ok
  end

  defp webhook(event) do
    conn(:post, "/pay/webhooks/paypal/site-a", JSON.encode!(event))
    |> put_req_header("paypal-auth-algo", "SHA256withRSA")
    |> put_req_header(
      "paypal-cert-url",
      "https://api.sandbox.paypal.com/v1/notifications/certs/C"
    )
    |> put_req_header("paypal-transmission-id", "T1")
    |> put_req_header("paypal-transmission-sig", "good")
    |> put_req_header("paypal-transmission-time", DateTime.to_iso8601(DateTime.utc_now()))
    |> Webhook.call(Webhook.init(at: "/pay/webhooks"))
  end

  defp work, do: Oban.drain_queue(queue: :mishka_pay_inbox, with_recursion: true)

  test "a PayPal sale is paid, kept, refunded and told by its webhooks like a Stripe one" do
    assert {:ok, %MishkaPay.Checkout{id: order}} =
             MishkaPay.checkout(%{
               provider: "paypal",
               tenant: "site-a",
               items: [%{name: "Ebook", amount: %{amount: "19.99", currency: "USD"}, quantity: 2}],
               success_url: "https://shop.test/thanks?session_id={CHECKOUT_SESSION_ID}",
               cancel_url: "https://shop.test/cart",
               reference: "order-77"
             })

    PayPalStub.order(order, "APPROVED")

    # The buyer closed the tab before coming back: the approval's webhook alone takes the money.
    approved = %{
      "id" => "WH-EVT-APPROVED",
      "event_type" => "CHECKOUT.ORDER.APPROVED",
      "resource_type" => "checkout-order",
      "create_time" => "2026-11-20T10:00:00Z",
      "resource" => %{"id" => order}
    }

    assert webhook(approved).status == 200
    work()

    assert [
             %{
               provider: "paypal",
               provider_id: ^order,
               status: :paid,
               reference: "order-77",
               charge_id: "CAPTURE" <> _ = capture
             } = row
           ] = Ash.read!(@payment, authorize?: false)

    assert [%{event_id: "WH-EVT-APPROVED", status: :processed, answer_status: 200}] =
             Ash.read!(@inbox, authorize?: false)

    # The buyer comes back later to the same success page a Stripe sale uses.
    assert {:ok, ^order} =
             MishkaPay.return_checkout_id("paypal", %{"token" => order, "PayerID" => "P1"})

    assert {:ok, %MishkaPay.Checkout{payment_id: ^order}} =
             MishkaPay.fetch_checkout("paypal", order, "site-a")

    assert {:ok, refunded} =
             row
             |> Ash.Changeset.for_update(:refund, %{amount: %{amount: "5.00", currency: "USD"}})
             |> Ash.update(authorize?: false)

    assert refunded.status == :partially_refunded

    refund_event = %{
      "id" => "WH-EVT-REFUNDED",
      "event_type" => "PAYMENT.CAPTURE.REFUNDED",
      "resource_type" => "refund",
      "create_time" => "2026-11-20T10:05:00Z",
      "resource" => %{
        "id" => "REFUND1",
        "links" => [
          %{
            "rel" => "up",
            "href" => "https://api-m.sandbox.paypal.com/v2/payments/captures/" <> capture
          }
        ]
      }
    }

    assert webhook(refund_event).status == 200
    work()

    assert [%{status: :partially_refunded}] = Ash.read!(@payment, authorize?: false)

    assert %{payment_id: ^order, status: :processed} =
             @inbox
             |> Ash.read!(authorize?: false)
             |> Enum.find(&(&1.event_id == "WH-EVT-REFUNDED"))
  end
end

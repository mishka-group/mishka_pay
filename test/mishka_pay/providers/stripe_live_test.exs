# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.StripeLiveTest do
  @moduledoc """
  Against a real Stripe account in test mode, the truth the mock server stands in for. It runs only
  with `STRIPE_SECRET_KEY` set to a test key (`sk_test_...`):

      STRIPE_SECRET_KEY=sk_test_... mix test --only stripe_live

  It pays with Stripe's test cards, so nothing is charged.
  """

  use ExUnit.Case, async: false

  alias MishkaPay.{Checkout, Client, Errors, Invoice, Payment, Refund, Subscription}
  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Providers.Stripe.TestClock
  alias MishkaPay.Support.StripeMock

  @moduletag :stripe_live

  setup do
    key = System.fetch_env!("STRIPE_SECRET_KEY")

    # A sandbox or test key only, full (sk_test_) or restricted (rk_test_): never a live key.
    assert String.starts_with?(key, ["sk_test_", "rk_test_"]),
           "STRIPE_SECRET_KEY must be a Stripe test key"

    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: key})
    MishkaPay.Test.stub_http(&StripeMock.forward(&1, "https://api.stripe.com"))
    %{key: key}
  end

  # A payment the way a buyer's browser makes one, with a Stripe test card.
  defp pay(key, card) do
    {:ok, %{status: status, body: body}} =
      Client.request(%{
        provider: "stripe",
        method: :post,
        base_url: "https://api.stripe.com",
        path: "/v1/payment_intents",
        auth: {:bearer, key},
        headers: %{"stripe-version" => Stripe.version()},
        form:
          Stripe.form(%{
            "amount" => 1999,
            "currency" => "usd",
            "payment_method" => card,
            "confirm" => "true",
            "automatic_payment_methods" => %{"enabled" => "true", "allow_redirects" => "never"}
          })
      })

    {status, body}
  end

  test "a checkout opens a real Checkout Session" do
    assert {:ok,
            %Checkout{
              id: "cs_test_" <> _ = id,
              url: "https://checkout.stripe.com/" <> _,
              status: :open,
              reference: reference
            }} =
             MishkaPay.checkout(%{
               provider: "stripe",
               items: [
                 %{
                   name: "Ebook",
                   amount: %{amount: "19.99", currency: "USD"},
                   tax_code: "txcd_10302000"
                 }
               ],
               success_url: "https://shop.test/thanks",
               cancel_url: "https://shop.test/cart",
               reference: "live-#{System.unique_integer([:positive])}"
             })

    assert {:ok, %Checkout{id: ^id, status: :open, reference: ^reference, payment_id: nil}} =
             MishkaPay.fetch_checkout("stripe", id)
  end

  test "a checkout can turn Stripe Managed Payments off for itself" do
    assert {:ok, %Checkout{status: :open}} =
             MishkaPay.checkout(%{
               provider: "stripe",
               items: [%{name: "Ebook", amount: %{amount: "19.99", currency: "USD"}}],
               success_url: "https://shop.test/thanks",
               cancel_url: "https://shop.test/cart",
               merchant_of_record: false
             })
  end

  test "a paid payment is read as paid and refunded once, in part, or many times when allowed",
       %{key: key} do
    {200, %{"id" => id}} = pay(key, "pm_card_mastercard")

    assert {:ok,
            %Payment{status: :paid, card_brand: "mastercard", card_last4: "4444", refunds: []}} =
             MishkaPay.fetch_payment("stripe", id)

    assert {:ok, %Refund{status: :succeeded}} =
             MishkaPay.refund(%{
               provider: "stripe",
               payment_id: id,
               amount: %{amount: "5", currency: "USD"}
             })

    assert {:ok, %Payment{status: :partially_refunded, refunds: [%Refund{status: :succeeded}]}} =
             MishkaPay.fetch_payment("stripe", id)

    assert {:error, %MishkaPay.Errors.Invalid{errors: [%{field: :payment_id}]}} =
             MishkaPay.refund(%{provider: "stripe", payment_id: id})

    MishkaPay.Test.put_keys("stripe", %{secret_key: key, refunds: :many})

    assert {:ok, %Refund{}} =
             MishkaPay.refund(%{provider: "stripe", payment_id: id, reference: "rest-#{id}"})

    assert {:ok, %Payment{status: :refunded}} = MishkaPay.fetch_payment("stripe", id)
  end

  test "a declined card is Stripe's 402 with its decline code", %{key: key} do
    assert {402, %{"error" => %{"decline_code" => "generic_decline"}}} =
             pay(key, "pm_card_chargeDeclined")
  end

  test "a real event from the sandbox, signed as Stripe signs it, becomes an Event", %{key: key} do
    {:ok, %{status: 200, body: %{"data" => [event | _]}}} =
      Client.request(%{
        provider: "stripe",
        base_url: "https://api.stripe.com",
        path: "/v1/events",
        params: [limit: 1],
        auth: {:bearer, key},
        headers: %{"stripe-version" => Stripe.version()}
      })

    body = JSON.encode!(event)
    time = System.system_time(:second)

    {:ok, keys} =
      MishkaPay.Credentials.builder(%{
        provider: "stripe",
        secret_key: key,
        webhook_secret: "whsec_live_test"
      })

    assert {:ok, %MishkaPay.Event{id: id, type: type, livemode: false}} =
             Stripe.verify_webhook(
               body,
               [
                 {"stripe-signature",
                  "t=#{time},v1=#{Stripe.signature(body, time, "whsec_live_test")}"}
               ],
               keys
             )

    assert id == event["id"]
    assert type == event["type"]
  end

  test "a subscription checkout opens on Stripe with a trial and reads back as a subscription" do
    assert {:ok, %Checkout{id: "cs_test_" <> _ = id, mode: :subscription, status: :open}} =
             MishkaPay.checkout(%{
               provider: "stripe",
               mode: :subscription,
               trial_days: 7,
               items: [
                 %{
                   name: "Pro plan",
                   amount: %{amount: "9", currency: "USD"},
                   interval: :month,
                   tax_code: "txcd_10103001"
                 }
               ],
               success_url: "https://shop.test/thanks",
               cancel_url: "https://shop.test/cart",
               reference: "live-sub-#{System.unique_integer([:positive])}"
             })

    assert {:ok, %Checkout{id: ^id, status: :open, subscription_id: nil}} =
             MishkaPay.fetch_checkout("stripe", id)
  end

  # A subscription the way Stripe's own tests make one: a customer on a test clock, a card on file
  # and a monthly price. The clock is Stripe's: it moves on its own servers, so the test asks it
  # until it says it is done, as Stripe's docs do.
  test "a subscription renews on Stripe's test clock, then is cancelled at the period's end, resumed and cancelled now",
       %{key: key} do
    {:ok, %TestClock{id: clock, frozen_time: now}} = TestClock.create(nil, name: "live renewal")

    try do
      {200, %{"id" => customer}} =
        stripe(key, :post, "/v1/customers", %{
          "test_clock" => clock,
          "email" => "renew@example.com"
        })

      {200, %{"id" => card}} =
        stripe(key, :post, "/v1/payment_methods/pm_card_mastercard/attach", %{
          "customer" => customer
        })

      {200, _customer} =
        stripe(key, :post, "/v1/customers/#{customer}", %{
          "invoice_settings" => %{"default_payment_method" => card}
        })

      {200, %{"id" => product}} = stripe(key, :post, "/v1/products", %{"name" => "Pro plan"})

      {200, %{"id" => id}} =
        stripe(key, :post, "/v1/subscriptions", %{
          "customer" => customer,
          "metadata" => %{"mishka_pay_reference" => "pro-live"},
          "items" => [
            %{
              "price_data" => %{
                "currency" => "usd",
                "product" => product,
                "unit_amount" => 900,
                "recurring" => %{"interval" => "month"}
              }
            }
          ]
        })

      assert {:ok, %Subscription{status: :active, reference: "pro-live", items: [plan]}} =
               MishkaPay.fetch_subscription("stripe", id)

      assert {plan.name, plan.interval, plan.amount} ==
               {"Pro plan", :month, Money.new(:USD, "9.00")}

      {:ok, %TestClock{}} = TestClock.advance(nil, clock, DateTime.add(now, 32, :day))
      :ready = clock_ready(clock, 60)

      assert {:ok, [%Invoice{status: :paid}, %Invoice{status: :paid} | _]} =
               MishkaPay.invoices("stripe", id)

      assert {:ok, %Subscription{status: :active, cancel_at_period_end: true}} =
               MishkaPay.cancel_subscription("stripe", id)

      assert {:ok, %Subscription{cancel_at_period_end: false}} =
               MishkaPay.resume_subscription("stripe", id)

      assert {:ok, %Subscription{status: :canceled}} =
               MishkaPay.cancel_subscription("stripe", id, nil, at: :now)
    after
      TestClock.delete(nil, clock)
    end
  end

  defp clock_ready(_clock, 0), do: :timeout

  defp clock_ready(clock, tries) do
    case TestClock.fetch(nil, clock) do
      {:ok, %TestClock{status: :ready}} ->
        :ready

      _advancing ->
        Process.sleep(1_000)
        clock_ready(clock, tries - 1)
    end
  end

  defp stripe(key, method, path, params) do
    body = if method == :get, do: :params, else: :form

    {:ok, %{status: status, body: answer}} =
      Client.request(
        Map.put(
          %{
            provider: "stripe",
            method: method,
            base_url: "https://api.stripe.com",
            path: path,
            auth: {:bearer, key},
            headers: %{"stripe-version" => Stripe.version()}
          },
          body,
          Stripe.form(params)
        )
      )

    {status, answer}
  end

  test "a payment that does not exist is a rejection" do
    assert {:error, %Errors.Rejected{status: 404, code: "resource_missing"}} =
             MishkaPay.fetch_payment("stripe", "pi_doesnotexist")
  end
end

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

  alias MishkaPay.{Checkout, Client, Errors, Payment, Refund}
  alias MishkaPay.Providers.Stripe
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
              id: "cs_test_" <> _,
              url: "https://checkout.stripe.com/" <> _,
              status: :open
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

  test "a paid payment is read as paid, refunded in part, then in full", %{key: key} do
    {200, %{"id" => id}} = pay(key, "pm_card_visa")

    assert {:ok, %Payment{status: :paid}} = MishkaPay.fetch_payment("stripe", id)

    assert {:ok, %Refund{status: :succeeded}} =
             MishkaPay.refund(%{
               provider: "stripe",
               payment_id: id,
               amount: %{amount: "5", currency: "USD"}
             })

    assert {:ok, %Payment{status: :partially_refunded}} = MishkaPay.fetch_payment("stripe", id)
    assert {:ok, %Refund{}} = MishkaPay.refund(%{provider: "stripe", payment_id: id})
    assert {:ok, %Payment{status: :refunded}} = MishkaPay.fetch_payment("stripe", id)
  end

  test "a declined card is Stripe's 402 with its decline code", %{key: key} do
    assert {402, %{"error" => %{"decline_code" => "generic_decline"}}} =
             pay(key, "pm_card_chargeDeclined")
  end

  test "a payment that does not exist is a rejection" do
    assert {:error, %Errors.Rejected{status: 404, code: "resource_missing"}} =
             MishkaPay.fetch_payment("stripe", "pi_doesnotexist")
  end
end

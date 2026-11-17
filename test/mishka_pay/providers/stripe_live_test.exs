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
  alias MishkaPay.Providers.Stripe.{TestClock, WebhookEndpoint}
  alias MishkaPay.Support.StripeMock

  @moduletag :stripe_live

  setup do
    key = System.fetch_env!("STRIPE_SECRET_KEY")

    # A sandbox or test key only, full (sk_test_) or restricted (rk_test_): never a live key.
    assert String.starts_with?(key, ["sk_test_", "rk_test_"]),
           "STRIPE_SECRET_KEY must be a Stripe test key"

    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: key})
    MishkaPay.Test.stub_http(&StripeMock.forward_live/1)
    %{key: key}
  end

  # A payment the way a buyer's browser makes one, with a Stripe test card; `extra` params such as
  # a manual capture.
  defp pay(key, card, extra \\ %{}) do
    {:ok, %{status: status, body: body}} =
      Client.request(%{
        provider: "stripe",
        method: :post,
        base_url: "https://api.stripe.com",
        path: "/v1/payment_intents",
        auth: {:bearer, key},
        headers: %{"stripe-version" => Stripe.version()},
        form:
          %{
            "amount" => 1999,
            "currency" => "usd",
            "payment_method" => card,
            "confirm" => "true",
            "automatic_payment_methods" => %{"enabled" => "true", "allow_redirects" => "never"}
          }
          |> Map.merge(extra)
          |> Stripe.form()
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
               reference: "live-#{run_id()}"
             })

    assert {:ok, %Checkout{id: ^id, status: :open, reference: ^reference, payment_id: nil}} =
             MishkaPay.fetch_checkout("stripe", id)
  end

  test "an embedded checkout answers the client secret its page needs, and may hold the money" do
    embedded = %{
      provider: "stripe",
      ui_mode: :embedded,
      items: [
        %{name: "Ebook", amount: %{amount: "19.99", currency: "USD"}, tax_code: "txcd_10302000"}
      ],
      return_url: "https://shop.test/return?session_id={CHECKOUT_SESSION_ID}"
    }

    assert {:ok,
            %Checkout{
              id: "cs_test_" <> _ = id,
              ui_mode: :embedded,
              client_secret: "cs_test_" <> _,
              url: nil,
              status: :open
            }} = MishkaPay.checkout(embedded)

    assert {:ok, %Checkout{id: ^id, ui_mode: :embedded, return_url: "https://shop.test/" <> _}} =
             MishkaPay.fetch_checkout("stripe", id)

    # This account sells with Managed Payments by default, which makes an invoice after payment.
    held = Map.put(embedded, :capture, :manual)

    assert {:error, %Errors.Rejected{code: "capture_invoice", param: "capture"}} =
             MishkaPay.checkout(held)

    assert {:ok, %Checkout{ui_mode: :embedded, capture: :manual, client_secret: "cs_test_" <> _}} =
             MishkaPay.checkout(Map.put(held, :merchant_of_record, false))
  end

  test "a held payment is authorized, captured in part and read as paid; another is let go",
       %{key: key} do
    manual = %{"capture_method" => "manual"}
    {200, %{"id" => id, "status" => "requires_capture"}} = pay(key, "pm_card_mastercard", manual)

    assert {:ok, %Payment{status: :authorized, amount_captured: nil}} =
             MishkaPay.fetch_payment("stripe", id)

    assert {:ok, %Payment{status: :paid, amount_captured: part}} =
             MishkaPay.capture_payment("stripe", id, nil,
               amount: %{amount: "12", currency: "USD"}
             )

    assert Money.equal?(part, Money.new(:USD, "12"))
    assert {:ok, %Payment{status: :paid, amount: asked}} = MishkaPay.fetch_payment("stripe", id)
    assert Money.equal?(asked, Money.new(:USD, "19.99"))

    # Only the part taken can go back.
    assert {:error, %Errors.Invalid{errors: [%{field: :amount}]}} =
             MishkaPay.refund(%{
               provider: "stripe",
               payment_id: id,
               amount: %{amount: "15", currency: "USD"}
             })

    {200, %{"id" => other}} = pay(key, "pm_card_mastercard", manual)

    assert {:ok, %Payment{id: ^other, status: :canceled}} =
             MishkaPay.cancel_payment("stripe", other)

    {200, %{"id" => whole}} = pay(key, "pm_card_mastercard", manual)

    assert {:ok, %Payment{status: :paid, amount_captured: all}} =
             MishkaPay.capture_payment("stripe", whole)

    assert Money.equal?(all, Money.new(:USD, "19.99"))
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

    assert {:ok, %Refund{id: rest_id}} =
             MishkaPay.refund(%{provider: "stripe", payment_id: id, reference: "rest-#{id}"})

    assert {:ok, %Payment{status: :refunded}} = MishkaPay.fetch_payment("stripe", id)

    since = DateTime.add(DateTime.utc_now(), -3600)

    assert {:ok, %MishkaPay.Page{items: [%MishkaPay.Event{type: "charge.refunded"} | _]}} =
             MishkaPay.list_events("stripe", nil, since: since, types: ["charge.refunded"])

    assert {:ok, %Refund{id: ^rest_id, payment_id: ^id, reference: "rest-" <> _, amount: rest}} =
             MishkaPay.fetch_refund("stripe", rest_id)

    assert Money.equal?(rest, Money.new(:USD, "14.99"))

    assert {:ok, %MishkaPay.Page{items: [%Refund{id: ^rest_id}, %Refund{payment_id: ^id}]}} =
             MishkaPay.list_refunds("stripe", nil, payment_id: id)
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
               reference: "live-sub-#{run_id()}"
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

      assert {:ok, %Invoice{total: next_total}} = MishkaPay.upcoming_invoice("stripe", id)
      assert Money.equal?(next_total, Money.new(:USD, "9.00"))

      # Past the renewal (day 30) and Stripe's 72-hour wait: an account with webhook endpoints has
      # each new bill finalized once its webhook is delivered, or 72 hours later at most.
      {:ok, %TestClock{}} = TestClock.advance(nil, clock, DateTime.add(now, 34, :day))
      :ready = clock_ready(clock, 60)

      assert {:ok, %MishkaPay.Page{items: [%Invoice{status: :paid}, %Invoice{status: :paid} | _]}} =
               MishkaPay.list_invoices("stripe", nil, subscription_id: id)

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

  @tag timeout: 300_000
  test "a plan change and a quantity change bill what their preview said, on a test clock", %{
    key: key
  } do
    {:ok, %TestClock{id: clock, frozen_time: start}} = TestClock.create(nil, name: "live change")

    try do
      {200, %{"id" => customer}} =
        stripe(key, :post, "/v1/customers", %{
          "test_clock" => clock,
          "email" => "change@example.com"
        })

      {200, %{"id" => card}} =
        stripe(key, :post, "/v1/payment_methods/pm_card_mastercard/attach", %{
          "customer" => customer
        })

      {200, _customer} =
        stripe(key, :post, "/v1/customers/#{customer}", %{
          "invoice_settings" => %{"default_payment_method" => card}
        })

      {:ok, %MishkaPay.Product{id: product}} =
        MishkaPay.create_product(%{provider: "stripe", name: "Plans #{clock}"})

      {:ok, %MishkaPay.Price{id: pro}} =
        MishkaPay.create_price(%{
          provider: "stripe",
          product_id: product,
          amount: %{amount: "9.00", currency: "USD"},
          interval: :month
        })

      {:ok, %MishkaPay.Price{id: team}} =
        MishkaPay.create_price(%{
          provider: "stripe",
          product_id: product,
          amount: %{amount: "29.00", currency: "USD"},
          interval: :month
        })

      {200, %{"id" => id}} =
        stripe(key, :post, "/v1/subscriptions", %{
          "customer" => customer,
          "items" => [%{"price" => pro}]
        })

      {:ok, %TestClock{}} = TestClock.advance(nil, clock, DateTime.add(start, 10, :day))
      :ready = clock_ready(clock, 60)
      {:ok, %TestClock{frozen_time: day_ten}} = TestClock.fetch(nil, clock)

      for change <- [
            %{price_id: team, proration: :always_invoice},
            %{quantity: 3, proration: :always_invoice}
          ] do
        change =
          Map.merge(change, %{provider: "stripe", subscription_id: id, proration_date: day_ten})

        assert {:ok, %Invoice{amount_due: due, lines: lines}} =
                 MishkaPay.preview_subscription_change(change)

        assert Enum.any?(lines, & &1.proration)
        assert Enum.any?(lines, &Decimal.negative?(&1.amount.amount))

        assert {:ok, %Subscription{latest_invoice_id: invoice_id, items: [item]}} =
                 MishkaPay.change_subscription(change)

        assert item.id == team

        assert {:ok, %Invoice{amount_due: billed, status: :paid}} =
                 MishkaPay.fetch_invoice("stripe", invoice_id)

        assert Money.equal?(billed, due)
      end

      assert {:ok, %Subscription{items: [%{quantity: 3}]}} =
               MishkaPay.fetch_subscription("stripe", id)

      later = DateTime.add(day_ten, 40, :day)

      assert {:ok, %Subscription{pause_behavior: :keep_as_draft, resumes_at: ^later}} =
               MishkaPay.pause_collection("stripe", id, nil,
                 behavior: :keep_as_draft,
                 resumes_at: later
               )

      assert {:ok, %Subscription{pause_behavior: nil}} = MishkaPay.resume_collection("stripe", id)
    after
      TestClock.delete(nil, clock)
    end
  end

  test "a payment with Stripe's dispute card gets a dispute, which is read, answered and listed",
       %{
         key: key
       } do
    {200, %{"id" => payment_id, "status" => "succeeded"}} = pay(key, "pm_card_createDispute")

    assert {:ok, %MishkaPay.Dispute{id: id, payment_id: ^payment_id, status: status}} =
             first_dispute(payment_id, 30)

    assert status in [:needs_response, :warning_needs_response]

    assert {:ok, %Payment{disputed: true}} = MishkaPay.fetch_payment("stripe", payment_id)

    assert {:ok, %MishkaPay.File{id: file_id}} = MishkaPay.upload_file(upload("download-log.png"))

    assert {:ok, %MishkaPay.Dispute{has_evidence: true}} =
             MishkaPay.update_dispute(%{
               provider: "stripe",
               dispute_id: id,
               evidence: %{
                 "uncategorized_text" => "winning_evidence",
                 "uncategorized_file" => file_id
               },
               submit: false
             })

    assert {:ok, %MishkaPay.Dispute{id: ^id}} = MishkaPay.fetch_dispute("stripe", id)
  end

  test "a dispute evidence file is uploaded to Stripe's files host, read back and linked" do
    assert {:ok,
            %MishkaPay.File{
              id: "file_" <> _ = id,
              purpose: :dispute_evidence,
              type: "png",
              size: size,
              expires_at: %DateTime{}
            }} = MishkaPay.upload_file(upload("screenshot.png"))

    # Stripe stores an image as it encodes it again, so its size is Stripe's, not the upload's.
    assert size > 0

    assert {:ok, %MishkaPay.File{id: ^id, filename: filename, purpose: :dispute_evidence}} =
             MishkaPay.fetch_file("stripe", id)

    assert filename =~ "screenshot"

    at = DateTime.add(DateTime.utc_now(), 3600)

    assert {:ok,
            %MishkaPay.FileLink{
              id: "link_" <> _,
              file_id: ^id,
              url: "https://files.stripe.com/links/" <> _,
              expired: false,
              expires_at: %DateTime{} = ends
            }} = MishkaPay.file_link("stripe", id, nil, expires_at: at)

    assert DateTime.to_unix(ends) == DateTime.to_unix(at)

    assert {:error, %Errors.Rejected{status: 404}} =
             MishkaPay.fetch_file("stripe", "file_doesnotexist")
  end

  defp upload(filename),
    do: %{
      provider: "stripe",
      purpose: :dispute_evidence,
      filename: filename,
      content_type: "image/png",
      content: png()
    }

  # A one-pixel PNG, made here: its header, one compressed row and its end, each chunk with its
  # CRC.
  defp png do
    chunk = fn type, data ->
      <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
    end

    <<0x89, "PNG\r\n", 0x1A, "\n">> <>
      chunk.("IHDR", <<1::32, 1::32, 8, 2, 0, 0, 0>>) <>
      chunk.("IDAT", :zlib.compress(<<0, 255, 0, 0>>)) <> chunk.("IEND", "")
  end

  # Stripe opens the test card's dispute a moment after the payment; ask until it is there.
  defp first_dispute(_payment_id, 0), do: :timeout

  defp first_dispute(payment_id, tries) do
    case MishkaPay.list_disputes("stripe", nil, payment_id: payment_id) do
      {:ok, %MishkaPay.Page{items: [dispute | _]}} ->
        {:ok, dispute}

      {:ok, %MishkaPay.Page{items: []}} ->
        Process.sleep(1_000)
        first_dispute(payment_id, tries - 1)
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

  test "a customer is deleted on Stripe for good: it reads back deleted, and a second delete is refused" do
    run = run_id()

    {:ok, %MishkaPay.Customer{id: id}} =
      MishkaPay.create_customer(%{
        provider: "stripe",
        email: "erase-#{run}@example.com",
        reference: "erase-#{run}"
      })

    assert :ok = MishkaPay.delete_customer("stripe", id)

    assert {:error, %Errors.Rejected{code: "customer_deleted"}} =
             MishkaPay.fetch_customer("stripe", id)

    assert {:error, %Errors.Rejected{status: 404, code: "resource_missing"}} =
             MishkaPay.delete_customer("stripe", id)
  end

  test "a customer's subscriptions are listed by price and status, and searched, then ended",
       %{key: key} do
    run = run_id()

    {:ok, %MishkaPay.Customer{id: customer}} =
      MishkaPay.create_customer(%{provider: "stripe", email: "subs-#{run}@example.com"})

    {:ok, %MishkaPay.Product{id: product} = made} =
      MishkaPay.create_product(%{provider: "stripe", name: "Listed plan #{run}"})

    on_exit(fn ->
      archive(key, made)
      cleanup(key, &delete_customer(customer, &1))
    end)

    {200, %{"id" => id, "items" => %{"data" => [%{"price" => %{"id" => price}}]}}} =
      stripe(key, :post, "/v1/subscriptions", %{
        "customer" => customer,
        "trial_period_days" => 7,
        "metadata" => %{"mishka_pay_reference" => "subs-#{run}"},
        "items" => [
          %{
            "price_data" => %{
              "currency" => "usd",
              "product" => product,
              "unit_amount" => 500,
              "recurring" => %{"interval" => "month"}
            }
          }
        ]
      })

    assert {:ok, %MishkaPay.Page{items: [%Subscription{id: ^id, status: :trialing} = listed]}} =
             MishkaPay.list_subscriptions("stripe", nil, customer_id: customer, price_id: price)

    assert {listed.reference, listed.customer_email} == {"subs-#{run}", "subs-#{run}@example.com"}
    assert [%{product_id: ^product, interval: :month}] = listed.items

    assert {:ok, %MishkaPay.Page{items: []}} =
             MishkaPay.list_subscriptions("stripe", nil, customer_id: customer, status: :active)

    assert {:ok, %MishkaPay.Page{}} =
             MishkaPay.search_subscriptions("stripe", nil,
               status: :trialing,
               reference: "subs-#{run}"
             )

    {:ok, %Subscription{status: :canceled}} =
      MishkaPay.cancel_subscription("stripe", id, nil, at: :now)

    assert {:ok, %MishkaPay.Page{items: []}} =
             MishkaPay.list_subscriptions("stripe", nil, customer_id: customer)

    assert {:ok, %MishkaPay.Page{items: [%Subscription{id: ^id, status: :canceled}]}} =
             MishkaPay.list_subscriptions("stripe", nil, customer_id: customer, status: :all)
  end

  test "a pending invoice item is added once per reference, changed, listed and removed",
       %{key: key} do
    run = run_id()

    {:ok, %MishkaPay.Customer{id: customer}} =
      MishkaPay.create_customer(%{provider: "stripe", email: "items-#{run}@example.com"})

    on_exit(fn -> cleanup(key, &delete_customer(customer, &1)) end)

    item = %{
      provider: "stripe",
      customer_id: customer,
      name: "Setup fee #{run}",
      amount: %{amount: "49.00", currency: "USD"},
      quantity: 2,
      reference: "setup-#{run}"
    }

    assert {:ok, %MishkaPay.InvoiceItem{id: "ii_" <> _ = id, invoice_id: nil} = made} =
             MishkaPay.create_invoice_item(item)

    assert {made.amount, made.total, made.reference} ==
             {Money.new(:USD, "49.00"), Money.new(:USD, "98.00"), "setup-#{run}"}

    assert {:ok, %MishkaPay.InvoiceItem{id: ^id}} = MishkaPay.create_invoice_item(item)

    assert {:ok, %MishkaPay.InvoiceItem{quantity: 3, total: total}} =
             MishkaPay.update_invoice_item(%{provider: "stripe", id: id, quantity: 3})

    assert total == Money.new(:USD, "147.00")

    assert {:ok, %MishkaPay.Page{items: [%MishkaPay.InvoiceItem{id: ^id}]}} =
             MishkaPay.list_invoice_items("stripe", nil, customer_id: customer, pending: true)

    assert :ok = MishkaPay.delete_invoice_item("stripe", id)

    assert {:ok, %MishkaPay.Page{items: []}} =
             MishkaPay.list_invoice_items("stripe", nil, customer_id: customer, pending: true)
  end

  defp delete_customer(id, keys) do
    with :ok <- Stripe.delete_customer(id, keys), do: {:ok, :deleted}
  end

  test "a refusal keeps Stripe's request id and error page, and its words show neither" do
    assert {:error,
            %Errors.Rejected{
              status: 404,
              code: "resource_missing",
              request_id: "req_" <> _ = request_id,
              doc_url: "https://" <> _ = doc_url
            } = error} = MishkaPay.fetch_payment("stripe", "pi_doesnotexist")

    refute Exception.message(error) =~ request_id
    refute Exception.message(error) =~ doc_url
  end

  test "a customer is made, changed, found by email and read on Stripe, and its portal opens" do
    run = run_id()
    email = "live-#{run}@example.com"
    reference = "user-live-#{run}"

    assert {:ok, %MishkaPay.Customer{id: id, reference: ^reference}} =
             MishkaPay.create_customer(%{
               provider: "stripe",
               email: email,
               name: "Live Buyer",
               reference: reference
             })

    assert {:ok, %{name: "Live Buyer 2"}} =
             MishkaPay.update_customer(%{provider: "stripe", id: id, name: "Live Buyer 2"})

    assert {:ok, %MishkaPay.Page{items: [%MishkaPay.Customer{id: ^id}]}} =
             MishkaPay.list_customers("stripe", nil, email: email)

    assert {:ok, %MishkaPay.Customer{email: ^email}} = MishkaPay.fetch_customer("stripe", id)

    session = %{provider: "stripe", customer_id: id, return_url: "https://shop.test/account"}

    assert {:ok,
            %MishkaPay.PortalSession{id: "bps_" <> _, url: "https://billing.stripe.com/" <> _}} =
             MishkaPay.portal_session(session)
  end

  test "a business buyer's VAT number is added to a new customer, listed and removed" do
    run = run_id()

    {:ok, %MishkaPay.Customer{id: customer_id}} =
      MishkaPay.create_customer(%{
        provider: "stripe",
        email: "vat-#{run}@example.com",
        reference: "vat-#{run}"
      })

    # Stripe's sandbox verifies an EU VAT number of 000000000.
    assert {:ok,
            %MishkaPay.TaxId{
              id: "txi_" <> _ = id,
              customer_id: ^customer_id,
              type: "eu_vat",
              value: "DE000000000",
              country: "DE",
              verification: check
            }} =
             MishkaPay.create_tax_id("stripe", customer_id, %{
               type: "eu_vat",
               value: "DE000000000"
             })

    assert check in [:pending, :verified]

    assert {:ok, %MishkaPay.Page{items: [%MishkaPay.TaxId{id: ^id}]}} =
             MishkaPay.list_tax_ids("stripe", customer_id)

    assert {:error, %Errors.Rejected{code: "tax_id_invalid"} = error} =
             MishkaPay.create_tax_id("stripe", customer_id, %{type: "eu_vat", value: "DE12"})

    assert Exception.message(error) =~ "tax id"

    assert :ok = MishkaPay.delete_tax_id("stripe", customer_id, id)
    assert {:ok, %MishkaPay.Page{items: []}} = MishkaPay.list_tax_ids("stripe", customer_id)
  end

  test "the tax on a sale outside Checkout is counted and recorded, or the account says Stripe Tax is off" do
    run = run_id()

    calculation = %{
      provider: "stripe",
      items: [
        %{
          reference: "ebook-#{run}",
          amount: %{amount: "20.00", currency: "EUR"},
          quantity: 2,
          tax_code: "txcd_10302000"
        }
      ],
      address: %{country: "DE", postal_code: "10115"},
      shipping: %{amount: "4.95", currency: "EUR"}
    }

    # The test account's own Stripe Tax settings decide which answer comes; they are never changed.
    case MishkaPay.calculate_tax(calculation) do
      {:ok,
       %MishkaPay.TaxCalculation{
         id: "taxcalc_" <> _ = id,
         amount_total: total,
         tax_amount_exclusive: tax,
         items: [%MishkaPay.TaxLine{reference: reference, amount_tax: %Money{}}]
       }} ->
        assert reference == "ebook-#{run}"
        # The line's amount is its whole: 20.00 for the two, then 4.95 shipping and the tax.
        expected = Money.add!(Money.new(:EUR, "24.95"), tax)
        assert Money.equal?(total, expected)

        assert {:ok,
                %MishkaPay.TaxTransaction{
                  id: "tax_" <> _ = recorded,
                  calculation_id: ^id,
                  reference: order
                }} = MishkaPay.record_tax("stripe", id, "order-#{run}")

        assert order == "order-#{run}"

        assert {:ok, %MishkaPay.TaxTransaction{id: ^recorded}} =
                 MishkaPay.record_tax("stripe", id, "order-#{run}")

      {:error, %Errors.Rejected{code: "tax_not_set_up"} = error} ->
        assert Exception.message(error) =~ "tax service is not turned on"
    end
  end

  test "a shipping rate is made and listed, and a checkout that ships opens with it and an inline rate" do
    run = run_id()

    assert {:ok, %MishkaPay.ShippingRate{id: "shr_" <> _ = rate_id, min_days: 1, max_days: 2}} =
             MishkaPay.create_shipping_rate(%{
               provider: "stripe",
               name: "Express #{run}",
               amount: %{amount: "9.90", currency: "EUR"},
               min_days: 1,
               max_days: 2,
               tax_code: "txcd_92010001"
             })

    assert {:ok, %MishkaPay.Page{items: [_ | _] = rates}} =
             MishkaPay.list_shipping_rates("stripe", nil, active: true, limit: 100)

    assert Enum.any?(rates, &(&1.id == rate_id))

    assert {:ok, %Checkout{id: "cs_test_" <> _ = id, status: :open}} =
             MishkaPay.checkout(%{
               provider: "stripe",
               merchant_of_record: false,
               items: [%{name: "Mug", amount: %{amount: "15.00", currency: "EUR"}}],
               success_url: "https://shop.test/thanks",
               cancel_url: "https://shop.test/cart",
               reference: "ship-#{run}",
               shipping_countries: ["NL", "DE"],
               shipping_rates: [
                 rate_id,
                 %{name: "Post", amount: %{amount: "4.95", currency: "EUR"}, max_days: 5}
               ]
             })

    # Stripe picks the first rate until the buyer picks another.
    assert {:ok, %Checkout{shipping_rate_id: ^rate_id, amount_shipping: shipping}} =
             MishkaPay.fetch_checkout("stripe", id)

    assert Money.equal?(shipping, Money.new(:EUR, "9.90"))
  end

  test "a promotion code lowers a real checkout, and an expired checkout cannot be paid" do
    run = run_id()

    {:ok, %MishkaPay.Coupon{id: coupon_id, valid: true}} =
      MishkaPay.create_coupon(%{provider: "stripe", name: "Live 20", percent_off: 20})

    on_exit(fn -> MishkaPay.delete_coupon("stripe", coupon_id) end)

    assert {:ok, %MishkaPay.PromotionCode{id: "promo_" <> _ = code_id, coupon_id: ^coupon_id}} =
             MishkaPay.create_promotion_code(%{
               provider: "stripe",
               coupon_id: coupon_id,
               code: "LIVE#{run}"
             })

    assert {:ok, %MishkaPay.Page{items: [%MishkaPay.PromotionCode{id: ^code_id}]}} =
             MishkaPay.list_promotion_codes("stripe", nil, code: "LIVE#{run}")

    assert {:ok, %Checkout{id: id, status: :open, amount_total: total, amount_discount: discount}} =
             MishkaPay.checkout(%{
               provider: "stripe",
               items: [
                 %{
                   name: "Ebook",
                   amount: %{amount: "20.00", currency: "USD"},
                   tax_code: "txcd_10302000"
                 }
               ],
               success_url: "https://shop.test/thanks",
               cancel_url: "https://shop.test/cart",
               reference: "live-promo-#{run}",
               discounts: [%{promotion_code_id: code_id}],
               expires_at: DateTime.add(DateTime.utc_now(), 3600)
             })

    assert Money.equal?(discount, Money.new(:USD, "4.00"))
    assert Money.compare(total, Money.new(:USD, "20.00")) == :lt

    assert {:ok, %Checkout{status: :expired}} = MishkaPay.expire_checkout("stripe", id)
    assert {:ok, %Checkout{status: :expired, url: nil}} = MishkaPay.fetch_checkout("stripe", id)
    assert {:error, %Errors.Rejected{status: 400}} = MishkaPay.expire_checkout("stripe", id)

    assert {:ok, %MishkaPay.PromotionCode{active: false}} =
             MishkaPay.update_promotion_code(%{provider: "stripe", id: code_id, active: false})
  end

  test "a product and its price live in Stripe's catalog, sell by price id, and lists page through" do
    run = run_id()

    assert {:ok, %MishkaPay.Product{id: product_id}} =
             MishkaPay.create_product(%{
               provider: "stripe",
               id: "live-#{run}",
               name: "Live ebook #{run}",
               tax_code: "txcd_10302000"
             })

    on_exit(fn -> MishkaPay.archive_product("stripe", product_id) end)

    assert {:ok, %MishkaPay.Price{id: price_id, product_id: ^product_id}} =
             MishkaPay.create_price(%{
               provider: "stripe",
               product_id: product_id,
               amount: %{amount: "12.00", currency: "USD"},
               lookup_key: "live-#{run}"
             })

    assert {:ok, %MishkaPay.Price{name: "Live ebook " <> _, amount: amount}} =
             MishkaPay.fetch_price("stripe", price_id)

    assert Money.equal?(amount, Money.new(:USD, "12.00"))

    assert {:ok, %MishkaPay.Page{items: [%MishkaPay.Price{id: ^price_id}]}} =
             MishkaPay.list_prices("stripe", nil, lookup_key: "live-#{run}")

    assert {:ok, %Checkout{id: checkout_id, status: :open, amount_total: total}} =
             MishkaPay.checkout(%{
               provider: "stripe",
               items: [%{id: price_id, quantity: 2}],
               success_url: "https://shop.test/thanks",
               cancel_url: "https://shop.test/cart",
               reference: "live-price-#{run}"
             })

    assert {:ok, %Checkout{items: [%MishkaPay.Price{} = sold]}} =
             MishkaPay.fetch_checkout("stripe", checkout_id)

    assert {sold.id, sold.product_id, sold.quantity, sold.name} ==
             {price_id, product_id, 2, "Live ebook #{run}"}

    assert Money.equal?(sold.amount, Money.new(:USD, "12.00"))

    assert Money.compare(total, Money.new(:USD, "12.00")) in [:eq, :gt]

    for list <- [
          &MishkaPay.list_products("stripe", nil, &1),
          &MishkaPay.list_payments("stripe", nil, &1),
          &MishkaPay.list_customers("stripe", nil, &1)
        ] do
      assert {:ok, %MishkaPay.Page{items: [first], has_more: true, next: next}} = list.(limit: 1)
      assert {:ok, %MishkaPay.Page{items: [second]}} = list.(limit: 1, after: next)
      assert first.id != second.id
      assert [_, _, _] = list |> MishkaPay.Page.stream() |> Enum.take(3)
    end

    assert {:ok, %MishkaPay.Price{active: false}} = MishkaPay.archive_price("stripe", price_id)
  end

  test "a one-off bill is made with its items, opened, sent, paid by hand, and another voided or given up" do
    run = run_id()

    {:ok, %MishkaPay.Customer{id: customer_id}} =
      MishkaPay.create_customer(%{
        provider: "stripe",
        email: "bill-#{run}@example.com",
        reference: "bill-#{run}"
      })

    # Stripe's search index takes up to a minute; an older customer is found at once.
    assert {:ok, %MishkaPay.Page{}} =
             MishkaPay.search_customers("stripe", nil, email: "bill-#{run}@example.com")

    {:ok, %MishkaPay.Product{id: product_id}} =
      MishkaPay.create_product(%{provider: "stripe", name: "Live bill #{run}"})

    {:ok, %MishkaPay.Price{id: price_id}} =
      MishkaPay.create_price(%{
        provider: "stripe",
        product_id: product_id,
        amount: %{amount: "5.00", currency: "USD"}
      })

    on_exit(fn ->
      MishkaPay.archive_price("stripe", price_id)
      MishkaPay.archive_product("stripe", product_id)
    end)

    draft = fn reference ->
      %{
        provider: "stripe",
        customer_id: customer_id,
        collection: :send_invoice,
        days_until_due: 7,
        description: "Setup work",
        reference: reference,
        items: [
          %{name: "Setup", amount: %{amount: "120.00", currency: "USD"}, quantity: 2},
          %{id: price_id, quantity: 3}
        ]
      }
    end

    assert {:ok, %Invoice{id: invoice_id, status: :draft, total: total, reference: reference}} =
             MishkaPay.create_invoice(draft.("bill-#{run}-1"))

    assert reference == "bill-#{run}-1"
    assert Money.equal?(total, Money.new(:USD, "255.00"))

    assert {:ok, %Invoice{id: ^invoice_id}} = MishkaPay.create_invoice(draft.("bill-#{run}-1"))

    assert {:ok,
            %Invoice{status: :open, number: number, hosted_url: "https://" <> _, due_at: due}} =
             MishkaPay.finalize_invoice("stripe", invoice_id)

    assert number =~ ~r/\w+-\d+/
    assert %DateTime{} = due
    assert {:ok, %Invoice{status: :open}} = MishkaPay.send_invoice("stripe", invoice_id)

    assert {:ok, %Invoice{status: :paid}} =
             MishkaPay.pay_invoice("stripe", invoice_id, nil, out_of_band: true)

    {:ok, %Invoice{id: second}} = MishkaPay.create_invoice(draft.("bill-#{run}-2"))
    {:ok, _open} = MishkaPay.finalize_invoice("stripe", second)
    assert {:ok, %Invoice{status: :void}} = MishkaPay.void_invoice("stripe", second)

    {:ok, %Invoice{id: third}} = MishkaPay.create_invoice(draft.("bill-#{run}-3"))
    {:ok, _open} = MishkaPay.finalize_invoice("stripe", third)

    assert {:ok, %Invoice{status: :uncollectible}} =
             MishkaPay.mark_invoice_uncollectible("stripe", third)

    {:ok, %Invoice{id: fourth}} = MishkaPay.create_invoice(draft.("bill-#{run}-4"))
    assert :ok = MishkaPay.delete_invoice("stripe", fourth)
    assert {:error, %Errors.Rejected{}} = MishkaPay.fetch_invoice("stripe", fourth)
  end

  test "a site's webhook endpoint is made with every handled event, then checked and deleted" do
    url = "https://example.com/pay/webhooks/stripe/live-#{run_id()}"

    assert {:ok, %WebhookEndpoint{id: id, secret: "whsec_" <> _, api_version: version}} =
             WebhookEndpoint.ensure(nil, url)

    on_exit(fn -> WebhookEndpoint.delete(nil, id) end)
    assert version == Stripe.version()
    assert {:ok, %{endpoint: %{id: ^id}, missing: []}} = WebhookEndpoint.check(nil, url)
    assert {:ok, %WebhookEndpoint{id: ^id, secret: nil}} = WebhookEndpoint.ensure(nil, url)
    assert :ok = WebhookEndpoint.delete(nil, id)
    assert {:ok, %{endpoint: nil}} = WebhookEndpoint.check(nil, url)
  end

  test "currencies Stripe counts differently from ISO 4217 are priced and read back as given" do
    run = run_id()

    assert {:ok, %MishkaPay.Product{id: product_id}} =
             MishkaPay.create_product(%{provider: "stripe", name: "Live currencies #{run}"})

    on_exit(fn -> MishkaPay.archive_product("stripe", product_id) end)

    for {currency, amount} <- [
          {"ISK", "500"},
          {"UGX", "3000"},
          {"MGA", "10000"},
          {"HUF", "175.50"}
        ] do
      assert {:ok, %MishkaPay.Price{id: price_id, amount: made}} =
               MishkaPay.create_price(%{
                 provider: "stripe",
                 product_id: product_id,
                 amount: %{amount: amount, currency: currency}
               })

      assert {:ok, %MishkaPay.Price{amount: read}} = MishkaPay.fetch_price("stripe", price_id)
      assert Money.equal?(made, Money.new(currency, amount))
      assert Money.equal?(read, Money.new(currency, amount))
      MishkaPay.archive_price("stripe", price_id)
    end
  end

  test "a one-time payment link, a checkout with its invoice, and prices that hold or add the tax" do
    run = run_id()

    {:ok, %MishkaPay.Product{id: product_id}} =
      MishkaPay.create_product(%{
        provider: "stripe",
        id: "live-link-#{run}",
        name: "Live link #{run}",
        tax_code: "txcd_10302000"
      })

    on_exit(fn -> MishkaPay.archive_product("stripe", product_id) end)

    assert {:ok, %MishkaPay.Price{id: price_id, tax_behavior: :exclusive}} =
             MishkaPay.create_price(%{
               provider: "stripe",
               product_id: product_id,
               amount: %{amount: "15.00", currency: "USD"},
               tax_behavior: :exclusive
             })

    assert {:ok,
            %MishkaPay.PaymentLink{
              id: "plink_" <> _ = link_id,
              url: "https://buy.stripe.com/" <> _,
              active: true,
              max_purchases: 1,
              purchases: 0,
              inactive_message: "Sold out",
              invoice: true
            } = link} =
             MishkaPay.create_payment_link(%{
               provider: "stripe",
               items: [%{id: price_id, quantity: 1}],
               success_url: "https://shop.test/thanks",
               max_purchases: 1,
               inactive_message: "Sold out",
               quantity_max: 3,
               invoice: true,
               customer_creation: :always
             })

    assert MishkaPay.PaymentLink.url(link, reference: "order-#{run}") =~
             "client_reference_id=order-"

    assert {:ok,
            %MishkaPay.PaymentLink{
              items: [%MishkaPay.Price{id: ^price_id}],
              quantity_min: nil,
              quantity_max: 3
            }} = MishkaPay.fetch_payment_link("stripe", link_id)

    assert {:ok, %MishkaPay.PaymentLink{active: false, max_purchases: 5}} =
             MishkaPay.update_payment_link(%{
               provider: "stripe",
               id: link_id,
               active: false,
               max_purchases: 5
             })

    assert {:ok, %Checkout{status: :open, invoice: true}} =
             MishkaPay.checkout(%{
               provider: "stripe",
               items: [%{id: price_id}],
               success_url: "https://shop.test/thanks",
               cancel_url: "https://shop.test/cart",
               reference: "live-invoice-#{run}",
               invoice: true
             })

    MishkaPay.Test.put_keys("stripe", %{
      secret_key: System.fetch_env!("STRIPE_SECRET_KEY"),
      automatic_tax: true
    })

    assert {:ok, %Checkout{status: :open}} =
             MishkaPay.checkout(%{
               provider: "stripe",
               items: [
                 %{
                   name: "Tax included",
                   amount: %{amount: "20.00", currency: "EUR"},
                   tax_code: "txcd_10302000",
                   tax_behavior: :inclusive
                 }
               ],
               success_url: "https://shop.test/thanks",
               cancel_url: "https://shop.test/cart",
               reference: "live-inclusive-#{run}"
             })

    MishkaPay.archive_price("stripe", price_id)
  end

  test "a checkout asks for a phone and questions, with a description and statement suffix, and a trial may start without a card" do
    assert {:ok, %Checkout{id: id, status: :open}} =
             MishkaPay.checkout(%{
               provider: "stripe",
               items: [%{name: "Workshop seat", amount: %{amount: "30", currency: "USD"}}],
               success_url: "https://shop.test/thanks",
               cancel_url: "https://shop.test/cart",
               phone: true,
               description: "Workshop order",
               statement_suffix: "WORKSHOP",
               merchant_of_record: false,
               submit_type: :book,
               fields: [
                 %{key: "certname", label: "Name on the certificate"},
                 %{
                   key: "seat",
                   label: "Seat",
                   type: :dropdown,
                   options: [%{value: "front", label: "Front"}, %{value: "back", label: "Back"}]
                 }
               ]
             })

    assert {:ok, %Checkout{field_values: %{"certname" => nil, "seat" => nil}}} =
             MishkaPay.fetch_checkout("stripe", id)

    assert {:ok, %Checkout{status: :open}} =
             MishkaPay.checkout(%{
               provider: "stripe",
               mode: :subscription,
               items: [%{name: "Pro", amount: %{amount: "9", currency: "USD"}, interval: :month}],
               trial_days: 7,
               card_required: false,
               merchant_of_record: false,
               success_url: "https://shop.test/thanks",
               cancel_url: "https://shop.test/plans"
             })
  end

  test "a saved card is listed, read, made the default and taken off, and a setup checkout opens for one",
       %{key: key} do
    run = run_id()

    {:ok, %MishkaPay.Customer{id: customer_id}} =
      MishkaPay.create_customer(%{
        provider: "stripe",
        email: "cards-#{run}@example.com",
        reference: "cards-live-#{run}"
      })

    {200, %{"id" => "pm_" <> _ = card}} =
      stripe(key, :post, "/v1/payment_methods/pm_card_visa/attach", %{"customer" => customer_id})

    assert {:ok,
            %MishkaPay.Page{
              items: [
                %MishkaPay.PaymentMethod{
                  id: ^card,
                  customer_id: ^customer_id,
                  type: "card",
                  card_brand: "visa",
                  card_last4: "4242"
                }
              ]
            }} = MishkaPay.list_payment_methods("stripe", nil, customer_id: customer_id)

    assert {:ok, %MishkaPay.PaymentMethod{id: ^card, card_exp_year: year}} =
             MishkaPay.fetch_payment_method("stripe", card)

    assert year > 2000

    assert {:ok, %MishkaPay.Customer{id: ^customer_id, default_payment_method: ^card}} =
             MishkaPay.set_default_payment_method("stripe", customer_id, card)

    assert {:ok, %MishkaPay.PaymentMethod{id: ^card, customer_id: nil}} =
             MishkaPay.detach_payment_method("stripe", card)

    assert {:ok, %MishkaPay.Page{items: []}} =
             MishkaPay.list_payment_methods("stripe", nil, customer_id: customer_id)

    setup = %{
      provider: "stripe",
      mode: :setup,
      currency: "usd",
      success_url: "https://shop.test/saved",
      cancel_url: "https://shop.test/account",
      reference: "card-live-#{run}"
    }

    assert {:ok, %Checkout{id: "cs_test_" <> _ = id, status: :open, url: "https://" <> _}} =
             MishkaPay.checkout(Map.put(setup, :customer, %{id: customer_id}))

    assert {:ok, %Checkout{id: ^id, status: :open, reference: "card-live-" <> _} = read} =
             MishkaPay.fetch_checkout("stripe", id)

    assert {read.customer.id, read.payment_method_id} == {customer_id, nil}

    assert {:ok, %Checkout{id: "cs_test_" <> _, status: :open}} =
             MishkaPay.checkout(%{setup | reference: "card-live-new-#{run}"})
  end

  # An on_exit callback runs in its own process, without the test's keys or HTTP stub: it calls
  # the adapter itself, with the test key and a stub of its own.
  defp cleanup(key, call) do
    MishkaPay.Test.stub_http(&StripeMock.forward(&1, "https://api.stripe.com"))
    assert {:ok, _done} = call.(%MishkaPay.Credentials{provider: "stripe", secret_key: key})
  end

  defp archive(key, %MishkaPay.Product{id: id}),
    do: cleanup(key, &Stripe.update_product(%MishkaPay.Product{id: id, active: false}, &1))

  test "a meter counts a customer's usage once per reference, a metered price bills it, and the meter is turned off",
       %{key: key} do
    run = run_id()
    event = "mishka_pay_live_#{run}"

    assert {:ok,
            %MishkaPay.Meter{
              id: "mtr_" <> _ = meter_id,
              event_name: ^event,
              aggregation: :sum,
              status: :active
            }} =
             MishkaPay.create_meter(%{provider: "stripe", name: "Live #{run}", event_name: event})

    # A meter is never deleted, only turned off.
    on_exit(fn ->
      cleanup(key, fn keys ->
        case Stripe.deactivate_meter(meter_id, keys) do
          {:error, %Errors.Rejected{message: "meter_already_deactivated"}} -> {:ok, :inactive}
          answer -> answer
        end
      end)
    end)

    assert %MishkaPay.Meter{id: ^meter_id} =
             (&MishkaPay.list_meters("stripe", nil, Keyword.merge([status: :active], &1)))
             |> MishkaPay.Page.stream()
             |> Enum.find(&(&1.id == meter_id))

    {:ok, %MishkaPay.Customer{id: customer_id}} =
      MishkaPay.create_customer(%{provider: "stripe", email: "usage-#{run}@example.com"})

    now = DateTime.utc_now()

    usage = %{
      provider: "stripe",
      event_name: event,
      customer_id: customer_id,
      value: 3,
      at: DateTime.add(now, -120),
      reference: "use-#{run}-1"
    }

    assert {:ok, %MishkaPay.Usage{id: "mishka_pay-usage-" <> _ = first}} =
             MishkaPay.report_usage(usage)

    assert {:ok, %MishkaPay.Usage{id: ^first}} = MishkaPay.report_usage(usage)

    assert {:ok, %MishkaPay.Usage{id: second}} =
             MishkaPay.report_usage(%{usage | value: "1.5", reference: "use-#{run}-2"})

    refute second == first

    # Stripe counts reports a little after they come in: the value is what it has counted so far.
    assert {:ok,
            %MishkaPay.UsageSummary{
              meter_id: ^meter_id,
              customer_id: ^customer_id,
              value: value,
              from: %DateTime{},
              to: %DateTime{}
            }} =
             MishkaPay.usage_summary(
               "stripe",
               meter_id,
               customer_id,
               DateTime.add(now, -3600),
               DateTime.add(now, 60)
             )

    # None, the first report, or both; Stripe may answer a whole number as a float.
    assert Enum.any?([0, 3, 4.5], &(&1 == value)), inspect(value)

    {:ok, %MishkaPay.Product{id: product_id} = product} =
      MishkaPay.create_product(%{provider: "stripe", name: "Live usage #{run}"})

    on_exit(fn -> archive(key, product) end)

    assert {:ok, %MishkaPay.Price{id: price_id, meter_id: ^meter_id, interval: :month}} =
             MishkaPay.create_price(%{
               provider: "stripe",
               product_id: product_id,
               amount: %{amount: "0.05", currency: "USD"},
               interval: :month,
               meter_id: meter_id
             })

    on_exit(fn ->
      cleanup(key, &Stripe.update_price(%MishkaPay.Price{id: price_id, active: false}, &1))
    end)

    assert {:ok, %MishkaPay.Price{meter_id: ^meter_id}} =
             MishkaPay.fetch_price("stripe", price_id)

    assert {:ok, %MishkaPay.Meter{id: ^meter_id, status: :inactive}} =
             MishkaPay.deactivate_meter("stripe", meter_id)
  end

  test "a feature is attached to a product, and a customer who bought nothing has no entitlements",
       %{key: key} do
    run = run_id()

    assert {:ok, %MishkaPay.Feature{id: "feat_" <> _ = feature_id, active: true}} =
             MishkaPay.create_feature(%{
               provider: "stripe",
               name: "Live #{run}",
               lookup_key: "mishka-pay-live-#{run}"
             })

    # A feature is never deleted, only turned off.
    on_exit(fn ->
      cleanup(key, fn keys ->
        path = "/v1/entitlements/features/#{feature_id}"
        Stripe.request(:post, path, %{"active" => false}, keys)
      end)
    end)

    {:ok, %MishkaPay.Product{id: product_id} = product} =
      MishkaPay.create_product(%{provider: "stripe", name: "Live feature #{run}"})

    on_exit(fn -> archive(key, product) end)

    assert {:ok, %MishkaPay.Feature{id: ^feature_id, lookup_key: "mishka-pay-live-" <> _}} =
             MishkaPay.attach_feature("stripe", product_id, feature_id)

    {:ok, %MishkaPay.Customer{id: customer_id}} =
      MishkaPay.create_customer(%{provider: "stripe", email: "feature-#{run}@example.com"})

    assert {:ok, %MishkaPay.Page{items: [], has_more: false}} =
             MishkaPay.list_entitlements("stripe", customer_id)
  end

  test "the balance is read, and its transactions page through, by type, with net as amount less fee" do
    assert {:ok, %MishkaPay.Balance{available: [_ | _] = available, pending: pending}} =
             MishkaPay.fetch_balance("stripe")

    assert Enum.all?(available ++ pending, &match?(%Money{}, &1))

    assert {:ok, %MishkaPay.Page{items: [_, _] = items, has_more: true, next: next}} =
             MishkaPay.list_balance_transactions("stripe", nil, limit: 2)

    for %MishkaPay.BalanceTransaction{id: "txn_" <> _} = txn <- items do
      assert Money.equal?(txn.net, Money.sub!(txn.amount, txn.fee))
      assert txn.status in [:available, :pending]
      assert %DateTime{} = txn.created_at
    end

    assert {:ok, %MishkaPay.Page{items: [%MishkaPay.BalanceTransaction{id: later} | _]}} =
             MishkaPay.list_balance_transactions("stripe", nil, limit: 2, after: next)

    refute later in Enum.map(items, & &1.id)

    assert {:ok, %MishkaPay.Page{items: [_ | _] = charges}} =
             MishkaPay.list_balance_transactions("stripe", nil, type: "charge", limit: 3)

    assert Enum.all?(charges, &(&1.type == "charge" and is_binary(&1.source_id)))
  end

  test "a customer's balance takes credit once per reference, then a debit, and lists both" do
    run = run_id()

    {:ok, %MishkaPay.Customer{id: customer_id}} =
      MishkaPay.create_customer(%{provider: "stripe", email: "credit-#{run}@example.com"})

    credit = fn ->
      MishkaPay.adjust_customer_balance(
        "stripe",
        customer_id,
        %{amount: "-5.00", currency: "USD"},
        nil,
        description: "Sorry for the outage",
        reference: "ticket-#{run}"
      )
    end

    assert {:ok,
            %MishkaPay.CustomerBalanceTransaction{
              id: "cbtxn_" <> _ = credit_id,
              customer_id: ^customer_id,
              amount: amount,
              ending_balance: after_credit,
              type: "adjustment",
              description: "Sorry for the outage",
              reference: "ticket-" <> _
            }} = credit.()

    assert Money.equal?(amount, Money.new(:USD, "-5.00"))
    assert Money.equal?(after_credit, Money.new(:USD, "-5.00"))
    assert {:ok, %MishkaPay.CustomerBalanceTransaction{id: ^credit_id}} = credit.()

    assert {:ok, %MishkaPay.CustomerBalanceTransaction{id: debit_id, ending_balance: ending}} =
             MishkaPay.adjust_customer_balance("stripe", customer_id, Money.new(:USD, "2.00"))

    assert Money.equal?(ending, Money.new(:USD, "-3.00"))

    assert {:ok,
            %MishkaPay.Page{
              items: [
                %MishkaPay.CustomerBalanceTransaction{id: ^debit_id},
                %MishkaPay.CustomerBalanceTransaction{id: ^credit_id}
              ]
            }} = MishkaPay.list_customer_balance("stripe", customer_id)
  end

  test "the setup check takes the sandbox keys" do
    assert {:keys_accepted, :ok} = List.keyfind(MishkaPay.Check.run([]), :keys_accepted, 0)
  end

  test "a payment that does not exist is a rejection" do
    assert {:error, %Errors.Rejected{status: 404, code: "resource_missing"}} =
             MishkaPay.fetch_payment("stripe", "pi_doesnotexist")
  end

  # Stripe and PayPal keep codes, lookup keys and idempotency keys between runs; a counter alone
  # starts again each run, so the run's time makes every name new.
  defp run_id, do: "#{System.os_time(:millisecond)}#{System.unique_integer([:positive])}"
end

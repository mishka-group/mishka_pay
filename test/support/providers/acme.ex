# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Acme do
  @moduledoc """
  A provider written by a project, as the docs of `MishkaPay.Provider` show it. It keeps nothing
  and calls nothing: its answers come from what it is given, so tests can tell each path apart.

    * A checkout whose reference is `"decline"` is declined; any other opens at a page named after
      the reference.
    * A payment id says its own status: `"acme_paid"`, `"acme_pending"`.
    * A subscription id says its own status: `"acme_sub_active"`, `"acme_sub_trialing"`.
    * Every operation answers only with the keys `"sk_acme"`.
  """

  use MishkaPay.Provider,
    id: "acme",
    label: "Acme Pay",
    capabilities: [
      :checkout,
      :expire,
      :payment_list,
      :refund,
      :subscription,
      :subscription_change,
      :customer,
      :portal,
      :discount,
      :catalog,
      :payment_link
    ],
    priority: 10

  alias MishkaPay.{
    Checkout,
    Coupon,
    Customer,
    Errors,
    Invoice,
    Page,
    Payment,
    PaymentLink,
    PortalSession,
    Price,
    Product,
    Refund,
    Subscription
  }

  @impl MishkaPay.Provider
  def checkout(%Checkout{reference: "decline"}, _keys),
    do: {:error, Errors.Declined.exception(provider: "acme", reason: "card_declined")}

  def checkout(%Checkout{} = checkout, %{secret_key: "sk_acme"}) do
    {:ok,
     %{
       checkout
       | id: "acme_cs_#{checkout.reference}",
         url: "https://pay.acme.test/#{checkout.reference}",
         status: :open
     }}
  end

  def checkout(_checkout, _keys),
    do: {:error, Errors.Declined.exception(provider: "acme", reason: "bad_keys")}

  @impl MishkaPay.Provider
  def fetch_checkout("acme_cs_" <> reference = id, %{secret_key: "sk_acme"}) do
    {:ok,
     struct(Checkout,
       provider: "acme",
       items: [],
       id: id,
       reference: reference,
       status: :complete,
       payment_id: "acme_paid"
     )}
  end

  @impl MishkaPay.Provider
  def fetch_payment("acme_" <> status = id, %{secret_key: "sk_acme"}) do
    Payment.builder(%{
      provider: "acme",
      id: id,
      amount: Elixir.Money.new(:USD, "19.99"),
      status: String.to_existing_atom(status)
    })
  end

  @impl MishkaPay.Provider
  def refund(%Refund{} = refund, %{secret_key: "sk_acme"}),
    do: {:ok, %{refund | id: "acme_re_1", status: :succeeded}}

  @impl MishkaPay.Provider
  def fetch_subscription("acme_sub_" <> status = id, %{secret_key: "sk_acme"}),
    do: subscription(id, String.to_existing_atom(status), false)

  @impl MishkaPay.Provider
  def cancel_subscription(id, :now, %{secret_key: "sk_acme"}),
    do: subscription(id, :canceled, false)

  def cancel_subscription(id, :period_end, %{secret_key: "sk_acme"}),
    do: subscription(id, :active, true)

  @impl MishkaPay.Provider
  def resume_subscription(id, %{secret_key: "sk_acme"}), do: subscription(id, :active, false)

  @impl MishkaPay.Provider
  def list_invoices(opts, %{secret_key: "sk_acme"}) do
    with {:ok, invoice} <-
           Invoice.builder(%{
             provider: "acme",
             id: "acme_in_1",
             subscription_id: opts[:subscription_id],
             status: :paid,
             amount_due: Elixir.Money.new(:USD, "9.00"),
             amount_paid: Elixir.Money.new(:USD, "9.00")
           }),
         do: page([invoice], opts)
  end

  @impl MishkaPay.Provider
  def list_payments(opts, %{secret_key: "sk_acme"} = keys) do
    {:ok, payment} = fetch_payment("acme_paid", keys)
    page(List.duplicate(payment, 3), opts)
  end

  # Three items or fewer, paged like a provider does: `after:` is the index already read.
  defp page(items, opts) do
    from = opts |> Keyword.get(:after, "0") |> String.to_integer()
    {taken, rest} = items |> Enum.drop(from) |> Enum.split(opts[:limit] || 10)
    more = rest != []

    {:ok,
     %Page{
       items: taken,
       has_more: more,
       next: (more && Integer.to_string(from + length(taken))) || nil
     }}
  end

  @impl MishkaPay.Provider
  def fetch_invoice(id, %{secret_key: "sk_acme"}) do
    Invoice.builder(%{
      provider: "acme",
      id: id,
      status: :paid,
      amount_due: Elixir.Money.new(:USD, "9.00"),
      lines: [%{description: "Pro plan", amount: Elixir.Money.new(:USD, "9.00"), quantity: 1}]
    })
  end

  @impl MishkaPay.Provider
  def change_subscription(change, %{secret_key: "sk_acme"}) do
    Subscription.builder(%{
      provider: "acme",
      id: change.subscription_id,
      status: :active,
      items: [
        %{
          id: change.price_id || "acme_price_pro",
          item_id: "acme_si_1",
          name: "Pro plan",
          amount: Elixir.Money.new(:USD, "9.00"),
          interval: :month,
          quantity: change.quantity || 1
        }
      ]
    })
  end

  @impl MishkaPay.Provider
  def preview_subscription_change(change, %{secret_key: "sk_acme"}) do
    Invoice.builder(%{
      provider: "acme",
      id: "acme_upcoming_#{change.proration_date && DateTime.to_unix(change.proration_date)}",
      status: :draft,
      amount_due: Elixir.Money.new(:USD, "4.50"),
      lines: [
        %{description: "Unused time", amount: Elixir.Money.new(:USD, "-4.50"), proration: true},
        %{description: "Remaining time", amount: Elixir.Money.new(:USD, "9.00"), proration: true}
      ]
    })
  end

  @impl MishkaPay.Provider
  def pause_collection(id, opts, %{secret_key: "sk_acme"}) do
    Subscription.builder(%{
      provider: "acme",
      id: id,
      status: :active,
      pause_behavior: opts[:behavior],
      resumes_at: opts[:resumes_at]
    })
  end

  @impl MishkaPay.Provider
  def resume_collection(id, %{secret_key: "sk_acme"}), do: subscription(id, :active, false)

  defp subscription(id, status, cancel_at_period_end) do
    Subscription.builder(%{
      provider: "acme",
      id: id,
      status: status,
      cancel_at_period_end: cancel_at_period_end,
      items: [%{name: "Pro plan", amount: Elixir.Money.new(:USD, "9.00"), interval: :month}]
    })
  end

  @impl MishkaPay.Provider
  def create_customer(%Customer{} = customer, %{secret_key: "sk_acme"}),
    do: {:ok, %{customer | id: "acme_cus_1"}}

  @impl MishkaPay.Provider
  def fetch_customer("acme_cus_gone", %{secret_key: "sk_acme"}),
    do:
      {:error, Errors.Rejected.exception(provider: "acme", status: 404, code: "customer_deleted")}

  def fetch_customer("acme_cus_" <> _ = id, %{secret_key: "sk_acme"}),
    do: Customer.builder(%{provider: "acme", id: id, email: "ava@example.com", name: "Ava"})

  @impl MishkaPay.Provider
  def update_customer(%Customer{} = customer, %{secret_key: "sk_acme"}), do: {:ok, customer}

  @impl MishkaPay.Provider
  def delete_customer("acme_cus_gone", %{secret_key: "sk_acme"}),
    do:
      {:error, Errors.Rejected.exception(provider: "acme", status: 404, code: "resource_missing")}

  def delete_customer("acme_cus_" <> _, %{secret_key: "sk_acme"}), do: :ok

  @impl MishkaPay.Provider
  def search_customers(opts, keys), do: list_customers(opts, keys)

  @impl MishkaPay.Provider
  def upcoming_invoice(_subscription_id, keys), do: fetch_invoice("acme_in_next", keys)

  @impl MishkaPay.Provider
  def list_customers(opts, %{secret_key: "sk_acme"}) do
    {:ok, customer} = fetch_customer("acme_cus_1", %{secret_key: "sk_acme"})
    page(List.duplicate(customer, 3), opts)
  end

  @impl MishkaPay.Provider
  def portal_session(%PortalSession{} = session, %{secret_key: "sk_acme"}),
    do:
      {:ok,
       %{
         session
         | id: "acme_portal_1",
           url: "https://pay.acme.test/portal/#{session.customer_id}"
       }}

  @impl MishkaPay.Provider
  def create_portal_configuration(%PortalSession.Configuration{} = config, %{
        secret_key: "sk_acme"
      }),
      do: {:ok, %{config | id: "acme_bpc_1", active: true, default: false}}

  @impl MishkaPay.Provider
  def update_portal_configuration(%PortalSession.Configuration{} = config, %{
        secret_key: "sk_acme"
      }),
      do: {:ok, config}

  @impl MishkaPay.Provider
  def fetch_portal_configuration("acme_bpc_" <> _ = id, %{secret_key: "sk_acme"}),
    do:
      PortalSession.Configuration.builder(%{
        provider: "acme",
        id: id,
        active: true,
        default: true
      })

  @impl MishkaPay.Provider
  def list_portal_configurations(_opts, %{secret_key: "sk_acme"} = keys) do
    with {:ok, config} <- fetch_portal_configuration("acme_bpc_1", keys),
         do: {:ok, struct(Page, items: [config])}
  end

  @impl MishkaPay.Provider
  def expire_checkout("acme_cs_" <> reference = id, %{secret_key: "sk_acme"}),
    do:
      {:ok,
       struct(Checkout,
         provider: "acme",
         items: [],
         id: id,
         reference: reference,
         status: :expired
       )}

  @impl MishkaPay.Provider
  def create_coupon(%Coupon{} = coupon, %{secret_key: "sk_acme"}),
    do: {:ok, %{coupon | id: coupon.id || "acme_coupon_1", valid: true, times_redeemed: 0}}

  @impl MishkaPay.Provider
  def fetch_coupon(id, %{secret_key: "sk_acme"}),
    do: Coupon.builder(%{provider: "acme", id: id, percent_off: 10, valid: true})

  @impl MishkaPay.Provider
  def list_coupons(opts, %{secret_key: "sk_acme"}) do
    {:ok, coupon} = fetch_coupon("acme_coupon_1", %{secret_key: "sk_acme"})
    page(List.duplicate(coupon, 2), opts)
  end

  @impl MishkaPay.Provider
  def delete_coupon(_id, %{secret_key: "sk_acme"}), do: :ok

  @impl MishkaPay.Provider
  def create_promotion_code(%Coupon.PromotionCode{} = code, %{secret_key: "sk_acme"}),
    do: {:ok, %{code | id: "acme_promo_1", code: code.code || "ACME10", active: true}}

  @impl MishkaPay.Provider
  def fetch_promotion_code(id, %{secret_key: "sk_acme"}),
    do:
      Coupon.PromotionCode.builder(%{
        provider: "acme",
        id: id,
        code: "ACME10",
        coupon_id: "acme_coupon_1",
        active: true
      })

  @impl MishkaPay.Provider
  def list_promotion_codes(opts, %{secret_key: "sk_acme"}) do
    {:ok, code} = fetch_promotion_code("acme_promo_1", %{secret_key: "sk_acme"})
    page(Enum.filter([code], &(opts[:code] in [nil, &1.code])), opts)
  end

  @impl MishkaPay.Provider
  def update_promotion_code(%Coupon.PromotionCode{} = code, %{secret_key: "sk_acme"}),
    do: {:ok, code}

  @impl MishkaPay.Provider
  def create_product(%Product{} = product, %{secret_key: "sk_acme"}),
    do: {:ok, %{product | id: product.id || "acme_prod_1", active: true}}

  @impl MishkaPay.Provider
  def fetch_product(id, %{secret_key: "sk_acme"}),
    do: Product.builder(%{provider: "acme", id: id, name: "Ebook", active: true})

  @impl MishkaPay.Provider
  def update_product(%Product{} = product, %{secret_key: "sk_acme"}), do: {:ok, product}

  @impl MishkaPay.Provider
  def list_products(opts, %{secret_key: "sk_acme"} = keys) do
    {:ok, product} = fetch_product("acme_prod_1", keys)
    page(List.duplicate(product, 3), opts)
  end

  @impl MishkaPay.Provider
  def create_price(%Price{} = price, %{secret_key: "sk_acme"}),
    do: {:ok, %{price | id: "acme_price_1", active: true}}

  @impl MishkaPay.Provider
  def fetch_price(id, %{secret_key: "sk_acme"}),
    do:
      Price.builder(%{
        provider: "acme",
        id: id,
        product_id: "acme_prod_1",
        amount: Elixir.Money.new(:USD, "19.99"),
        active: true
      })

  @impl MishkaPay.Provider
  def update_price(%Price{} = price, %{secret_key: "sk_acme"}), do: {:ok, price}

  @impl MishkaPay.Provider
  def list_prices(opts, %{secret_key: "sk_acme"} = keys) do
    {:ok, price} = fetch_price("acme_price_1", keys)
    page([price], opts)
  end

  @impl MishkaPay.Provider
  def create_payment_link(%PaymentLink{} = link, %{secret_key: "sk_acme"}),
    do: {:ok, %{link | id: "acme_link_1", url: "https://pay.acme.test/l/1", active: true}}

  @impl MishkaPay.Provider
  def fetch_payment_link(id, %{secret_key: "sk_acme"}),
    do:
      PaymentLink.builder(%{
        provider: "acme",
        id: id,
        url: "https://pay.acme.test/l/1",
        active: true,
        max_purchases: 1,
        purchases: 0
      })

  @impl MishkaPay.Provider
  def list_payment_links(opts, %{secret_key: "sk_acme"} = keys) do
    {:ok, link} = fetch_payment_link("acme_link_1", keys)
    page(List.duplicate(link, 2), opts)
  end

  @impl MishkaPay.Provider
  def update_payment_link(%PaymentLink{} = link, %{secret_key: "sk_acme"}), do: {:ok, link}
end

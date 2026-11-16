# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Object.Spec do
    @moduledoc """
    What the provider objects a site manages from its admin keep and do, kind by kind: products,
    prices, coupons, promotion codes, payment links and one-off bills (the `:product`, `:price`,
    `:coupon`, `:promotion_code`, `:payment_link` and `:invoice` kinds of
    `MishkaPay.Ash.Resource`). Each kind names the provider object its webhook events are about,
    how to read one again, the row it writes from the provider's answer, and the `MishkaPay` call
    of each of its actions. `MishkaPay.Ash.Object.Change` and `MishkaPay.Ash.Object.Listener` run
    them.
    """

    alias MishkaPay.{Coupon, Invoice, PaymentLink, Price, Product, PromotionCode}

    @kinds [:product, :price, :coupon, :promotion_code, :payment_link, :invoice]

    @doc "The kinds of provider objects a site manages from its admin."
    @spec kinds() :: [atom()]
    def kinds, do: @kinds

    @doc "The provider's name of the object a kind keeps, as its webhook events name it."
    @spec object(atom()) :: String.t()
    def object(kind), do: Atom.to_string(kind)

    @doc "The `:sync` argument that names the object: `:product_id`, `:invoice_id`..."
    @spec id_argument(atom()) :: atom()
    def id_argument(kind), do: :"#{kind}_id"

    @doc "Reads one object of `kind` again from its provider."
    @spec fetch(atom(), String.t(), String.t(), term()) :: {:ok, struct()} | {:error, term()}
    def fetch(:product, provider, id, tenant), do: MishkaPay.fetch_product(provider, id, tenant)
    def fetch(:price, provider, id, tenant), do: MishkaPay.fetch_price(provider, id, tenant)
    def fetch(:coupon, provider, id, tenant), do: MishkaPay.fetch_coupon(provider, id, tenant)

    def fetch(:promotion_code, provider, id, tenant),
      do: MishkaPay.fetch_promotion_code(provider, id, tenant)

    def fetch(:payment_link, provider, id, tenant),
      do: MishkaPay.fetch_payment_link(provider, id, tenant)

    def fetch(:invoice, provider, id, tenant), do: MishkaPay.fetch_invoice(provider, id, tenant)

    @doc """
    The `MishkaPay` call of an action: `:add` makes the object from the action's input, the
    others act on the row's object. `input` holds the action's arguments set, with `:provider`,
    `:tenant` and, on a row, `:id`.
    """
    @spec call(atom(), atom(), map()) :: {:ok, struct()} | :ok | {:error, term()}
    def call(:product, :add, input), do: MishkaPay.create_product(input)
    def call(:product, :edit, input), do: MishkaPay.update_product(input)

    def call(:product, :archive, %{provider: p, id: id, tenant: t}),
      do: MishkaPay.archive_product(p, id, t)

    def call(:price, :add, input), do: MishkaPay.create_price(input)

    def call(:price, :archive, %{provider: p, id: id, tenant: t}),
      do: MishkaPay.archive_price(p, id, t)

    def call(:coupon, :add, input), do: MishkaPay.create_coupon(input)

    def call(:coupon, :remove, %{provider: p, id: id, tenant: t}),
      do: MishkaPay.delete_coupon(p, id, t)

    def call(:promotion_code, :add, input), do: MishkaPay.create_promotion_code(input)
    def call(:promotion_code, :edit, input), do: MishkaPay.update_promotion_code(input)
    def call(:payment_link, :add, input), do: MishkaPay.create_payment_link(merged(input, :link))

    def call(:payment_link, :edit, input),
      do: MishkaPay.update_payment_link(merged(input, :changes))

    def call(:invoice, :add, input), do: MishkaPay.create_invoice(merged(input, :draft))

    def call(:invoice, :finalize, %{provider: p, id: id, tenant: t}),
      do: MishkaPay.finalize_invoice(p, id, t)

    def call(:invoice, :send, %{provider: p, id: id, tenant: t}),
      do: MishkaPay.send_invoice(p, id, t)

    def call(:invoice, :pay, %{provider: p, id: id, tenant: t} = input),
      do: MishkaPay.pay_invoice(p, id, t, out_of_band: Map.get(input, :out_of_band, false))

    def call(:invoice, :void, %{provider: p, id: id, tenant: t}),
      do: MishkaPay.void_invoice(p, id, t)

    def call(:invoice, :mark_uncollectible, %{provider: p, id: id, tenant: t}),
      do: MishkaPay.mark_invoice_uncollectible(p, id, t)

    def call(:invoice, :remove, %{provider: p, id: id, tenant: t}),
      do: MishkaPay.delete_invoice(p, id, t)

    # A map argument (a payment link's setup, a bill's draft) is the call's input, with the row's
    # provider, tenant and id under the same kind of keys as the map's own.
    defp merged(input, name) do
      {nested, rest} = Map.pop(input, name, %{})

      case Enum.any?(Map.keys(nested), &is_binary/1) do
        true -> Map.merge(nested, Map.new(rest, fn {key, value} -> {to_string(key), value} end))
        false -> Map.merge(nested, rest)
      end
    end

    @doc "The row's attributes from the provider's object."
    @spec attributes(struct()) :: map()
    def attributes(%Product{} = product) do
      %{
        name: product.name,
        description: product.description,
        tax_code: product.tax_code,
        active: product.active,
        default_price_id: product.default_price_id,
        metadata: product.metadata || %{}
      }
      |> common(product)
    end

    def attributes(%Price{} = price) do
      %{
        product_id: price.product_id,
        name: price.name,
        amount: price.amount && price.amount.amount,
        currency: price.amount && to_string(price.amount.currency),
        interval: price.interval,
        interval_count: price.interval_count,
        tax_behavior: price.tax_behavior,
        lookup_key: price.lookup_key,
        active: price.active,
        metadata: price.metadata || %{}
      }
      |> common(price)
    end

    def attributes(%Coupon{} = coupon) do
      %{
        name: coupon.name,
        percent_off: coupon.percent_off,
        amount_off: coupon.amount_off && coupon.amount_off.amount,
        currency: coupon.amount_off && to_string(coupon.amount_off.currency),
        duration: coupon.duration,
        duration_in_months: coupon.duration_in_months,
        max_redemptions: coupon.max_redemptions,
        redeem_by: coupon.redeem_by,
        valid: coupon.valid,
        times_redeemed: coupon.times_redeemed,
        metadata: coupon.metadata || %{}
      }
      |> common(coupon)
    end

    def attributes(%PromotionCode{} = code) do
      %{
        code: code.code,
        coupon_id: code.coupon_id,
        active: code.active,
        max_redemptions: code.max_redemptions,
        times_redeemed: code.times_redeemed,
        expires_at: code.expires_at,
        first_time_transaction: code.first_time_transaction,
        minimum_amount: code.minimum_amount && code.minimum_amount.amount,
        currency: code.minimum_amount && to_string(code.minimum_amount.currency),
        customer_id: code.customer_id,
        metadata: code.metadata || %{}
      }
      |> common(code)
    end

    def attributes(%PaymentLink{} = link) do
      %{
        url: link.url,
        active: link.active,
        price_ids: link.items |> List.wrap() |> Enum.flat_map(&List.wrap(&1.id)),
        max_purchases: link.max_purchases,
        purchases: link.purchases,
        metadata: link.metadata || %{}
      }
      |> common(link)
    end

    def attributes(%Invoice{} = invoice) do
      money = invoice.total || invoice.amount_due

      %{
        status: invoice.status,
        number: invoice.number,
        customer_id: invoice.customer_id,
        subscription_id: invoice.subscription_id,
        collection: invoice.collection,
        amount_due: invoice.amount_due && invoice.amount_due.amount,
        amount_paid: invoice.amount_paid && invoice.amount_paid.amount,
        total: invoice.total && invoice.total.amount,
        currency: money && to_string(money.currency),
        hosted_url: invoice.hosted_url,
        pdf_url: invoice.pdf_url,
        due_at: invoice.due_at,
        payment_id: invoice.payment_id,
        reference: invoice.reference
      }
      |> common(invoice)
    end

    defp common(attributes, object) do
      Map.merge(attributes, %{
        provider: object.provider,
        provider_id: object.id,
        provider_created_at: Map.get(object, :created_at),
        deleted_at: nil
      })
    end
  end
end

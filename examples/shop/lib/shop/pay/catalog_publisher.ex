defmodule Shop.Pay.CatalogPublisher do
  @moduledoc """
  Publishes the shop's products to Stripe's catalog with Mishka Pay's catalog calls, so checkouts
  sell Stripe prices by their id:

    * the Stripe product is `shop-<slug>`: read again when it exists (`MishkaPay.fetch_product/3`)
      and brought up to date (`MishkaPay.update_product/1`), made otherwise
      (`MishkaPay.create_product/1`);
    * the price is found by its lookup key (`MishkaPay.list_prices/3`), which names its slug,
      amount and schedule, or made (`MishkaPay.create_price/1`). A changed amount makes a new
      price, and the old one is archived (`MishkaPay.archive_price/3`): a Stripe price never
      changes its amount.

  Publishing again changes nothing that is already right.
  """

  alias MishkaPay.Errors
  alias Shop.Catalog.Product

  @doc """
  Publishes every product of the shop, four at a time, and answers each with what happened.
  """
  @spec all(String.t()) :: [{Product.t(), :ok | {:error, term()}}]
  def all(tenant) do
    Shop.Catalog.all()
    |> Task.async_stream(&{&1, publish(&1, tenant)}, max_concurrency: 4, timeout: 60_000)
    |> Enum.map(fn
      {:ok, {product, {:ok, _row}}} -> {product, :ok}
      {:ok, {product, {:error, error}}} -> {product, {:error, error}}
    end)
  end

  @doc "Publishes one product and its price, and keeps their Stripe ids on the product."
  @spec publish(Product.t(), String.t()) :: {:ok, Product.t()} | {:error, term()}
  def publish(%Product{} = product, tenant) do
    with {:ok, stripe_product} <- product(product, tenant),
         {:ok, price} <- price(product, stripe_product.id, tenant),
         :ok <- archive_old(product, price.id, tenant) do
      product
      |> Ash.Changeset.for_update(:published, %{
        stripe_product_id: stripe_product.id,
        stripe_price_id: price.id
      })
      |> Ash.update(authorize?: false)
    end
  end

  defp product(product, tenant) do
    attrs = %{
      provider: "stripe",
      tenant: tenant,
      id: "shop-#{product.slug}",
      name: product.name,
      tax_code: product.tax_code,
      active: true
    }

    case MishkaPay.fetch_product("stripe", attrs.id, tenant) do
      {:ok, _found} -> MishkaPay.update_product(attrs)
      {:error, %Errors.Rejected{code: "resource_missing"}} -> MishkaPay.create_product(attrs)
      {:error, error} -> {:error, error}
    end
  end

  defp price(product, product_id, tenant) do
    key = lookup_key(product)

    case MishkaPay.list_prices("stripe", tenant, lookup_key: key, active: true, limit: 1) do
      {:ok, %MishkaPay.Page{items: [price | _]}} ->
        {:ok, price}

      {:ok, %MishkaPay.Page{items: []}} ->
        MishkaPay.create_price(%{
          provider: "stripe",
          tenant: tenant,
          product_id: product_id,
          amount: %{amount: product.price, currency: "USD"},
          interval: product.interval,
          interval_count: product.interval && product.interval_count,
          lookup_key: key
        })

      {:error, error} ->
        {:error, error}
    end
  end

  # A price the product sold before and no longer sells.
  defp archive_old(%{stripe_price_id: old}, new, tenant) when is_binary(old) and old != new do
    case MishkaPay.archive_price("stripe", old, tenant) do
      {:ok, _archived} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp archive_old(_product, _same, _tenant), do: :ok

  # The slug, the amount in cents and the schedule: a new amount is a new price.
  defp lookup_key(product) do
    cents = product.price |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
    every = if product.interval, do: "#{product.interval_count}#{product.interval}", else: "once"
    "shop-#{product.slug}-#{cents}-#{every}"
  end
end

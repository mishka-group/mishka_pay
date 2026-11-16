defmodule Shop.Catalog do
  @moduledoc """
  What the demo shop sells: `Shop.Catalog.Product` rows, filled by the seeds. A payment carries its
  product in its reference (`"<slug>-<uuid>"`), so the page names a payment by it.
  """

  require Ash.Query

  alias Shop.Catalog.Product

  @doc "Everything on sale, in its order: products paid once, then plans."
  def all do
    Product
    |> Ash.Query.filter(active == true)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(authorize?: false)
  end

  @doc "Whether `product` is a plan, sold as a subscription."
  def plan?(%{interval: interval}), do: not is_nil(interval)

  @doc "The product with `slug`, or nil."
  def fetch(slug) do
    Product
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read_one!(authorize?: false)
  end

  @doc "Every product's name by its slug, for naming payments without a query each."
  def names, do: Map.new(Ash.read!(Product, authorize?: false), &{&1.slug, &1.name})

  @doc "A new reference for a sale of `product`."
  def reference(%{slug: slug}), do: "#{slug}-#{Ecto.UUID.generate()}"

  @doc "The product name a payment's reference points at, from `names/0`."
  def name_of(reference, names) when is_binary(reference) do
    [slug | _] = String.split(reference, "-", parts: 2)
    Map.get(names, slug, "Sandbox payment")
  end

  def name_of(_reference, _names), do: "Sandbox payment"
end

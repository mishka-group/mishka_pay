defmodule Shop.Catalog do
  @moduledoc """
  What the demo shop sells. A payment carries its product in its reference (`"<product id>-<uuid>"`),
  so the page names a payment by it.
  """

  @products [
    %{id: "ebook", name: "Elixir ebook", price: "19.99", icon: "hero-book-open"},
    %{id: "course", name: "LiveView course", price: "49.00", icon: "hero-play-circle"},
    %{id: "stickers", name: "Sticker pack", price: "4.50", icon: "hero-sparkles"},
    %{id: "workshop", name: "Phoenix workshop", price: "129.00", icon: "hero-academic-cap"},
    %{id: "ashbook", name: "Ash framework book", price: "34.00", icon: "hero-book-open"},
    %{id: "hoodie", name: "Elixir hoodie", price: "39.00", icon: "hero-gift"}
  ]

  @doc "Every product, in the order the page shows them."
  def all, do: @products

  @doc "The product with `id`, or nil."
  def fetch(id), do: Enum.find(@products, &(&1.id == id))

  @doc "A new reference for a sale of `product`."
  def reference(%{id: id}), do: "#{id}-#{Ecto.UUID.generate()}"

  @doc "The product name a payment's reference points at."
  def name_of(reference) when is_binary(reference) do
    [id | _] = String.split(reference, "-", parts: 2)

    case fetch(id) do
      %{name: name} -> name
      nil -> "Sandbox payment"
    end
  end

  def name_of(_reference), do: "Sandbox payment"
end

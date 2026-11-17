defmodule ShopWeb.CatalogComponent do
  @moduledoc """
  The catalog part of the demo shop: publish the shop's seeded products and plans to Stripe's
  catalog (`Shop.Pay.CatalogPublisher`, on `MishkaPay.create_product/1`,
  `MishkaPay.create_price/1` and the rest), see each one's Stripe product and price, and read
  Stripe's own catalog back page by page (`MishkaPay.list_products/3`, `MishkaPay.list_prices/3`),
  where a product or a price can be archived (`MishkaPay.archive_product/3`,
  `MishkaPay.archive_price/3`). Once published, a checkout sells the Stripe price by its id.
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @page 5

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         products: [],
         stripe: [],
         next: nil,
         prices: %{},
         open: nil,
         active: "true",
         publishing?: false,
         loaded?: false
       )}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, tenant: assigns.tenant)

    case socket.assigns.loaded? do
      true ->
        {:ok, socket}

      false ->
        {:ok, socket |> assign(loaded?: true, products: Shop.Catalog.all()) |> first_page()}
    end
  end

  @impl true
  def handle_event("publish", _params, socket) do
    tenant = socket.assigns.tenant

    {:noreply,
     socket
     |> assign(publishing?: true)
     |> start_async(:publish, fn -> Shop.Pay.CatalogPublisher.all(tenant) end)}
  end

  def handle_event("filter", %{"active" => active}, socket),
    do: {:noreply, socket |> assign(active: active) |> first_page()}

  def handle_event("more", _params, socket), do: {:noreply, page(socket, socket.assigns.next)}

  def handle_event("open", %{"id" => id}, socket) do
    case socket.assigns.open do
      ^id -> {:noreply, assign(socket, open: nil)}
      _other -> {:noreply, socket |> assign(open: id) |> load_prices(id)}
    end
  end

  def handle_event("archive_product", %{"id" => id}, socket) do
    case MishkaPay.archive_product("stripe", id, socket.assigns.tenant) do
      {:ok, _product} ->
        {:noreply,
         socket
         |> first_page()
         |> say(:info, "Product archived: it stays for past sales, off sale from now on.")}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("archive_price", %{"id" => id, "product_id" => product_id}, socket) do
    case MishkaPay.archive_price("stripe", id, socket.assigns.tenant) do
      {:ok, _price} ->
        {:noreply,
         socket
         |> load_prices(product_id)
         |> say(:info, "Price archived: checkouts can no longer sell it.")}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  # Publishing asks Stripe a few times per product, so it runs apart from the page.
  @impl true
  def handle_async(:publish, {:ok, results}, socket) do
    failed =
      for {product, {:error, error}} <- results,
          do: "#{product.name}: #{MishkaPay.Ash.message(error)}"

    send(self(), :catalog_published)

    socket =
      socket
      |> assign(publishing?: false, products: Shop.Catalog.all())
      |> first_page()

    case failed do
      [] -> {:noreply, say(socket, :info, "#{length(results)} products are in Stripe's catalog.")}
      _some -> {:noreply, say(socket, :error, Enum.join(failed, "; "))}
    end
  end

  def handle_async(:publish, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(publishing?: false)
     |> say(:error, "Publishing stopped: #{inspect(reason)}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="catalog" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <.section_title icon="hero-squares-2x2" title="Stripe catalog" />
        <button
          class="btn btn-sm btn-primary"
          phx-click="publish"
          phx-target={@myself}
          disabled={@publishing?}
          data-testid="catalog-publish"
        >
          <span :if={@publishing?} class="loading loading-spinner loading-xs"></span>
          <.icon :if={!@publishing?} name="hero-arrow-up-tray" class="size-4" />
          {if @publishing?, do: "Publishing to Stripe...", else: "Publish the shop's products"}
        </button>
      </div>
      <p class="text-sm opacity-70">
        Publishing puts each product and plan in Stripe's catalog with its price. From then on, a
        checkout sells the Stripe price by its id. Publishing again changes only what changed.
      </p>

      <div class="overflow-x-auto rounded-box border border-base-300" data-testid="catalog-shop">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>In the shop</th>
              <th>Stripe product</th>
              <th>Stripe price</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={product <- @products}
              data-testid="catalog-shop-row"
              data-slug={product.slug}
              data-published={to_string(not is_nil(product.stripe_price_id))}
            >
              <td>{product.name}</td>
              <td class="font-mono text-xs">{product.stripe_product_id || "not published"}</td>
              <td class="font-mono text-xs">{product.stripe_price_id || "–"}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="flex flex-wrap items-center gap-3">
        <h3 class="font-medium">Read from Stripe</h3>
        <.hint>MishkaPay.list_products/3, {@page_size} a page</.hint>
        <form
          id="catalog-filter"
          phx-change="filter"
          phx-target={@myself}
          data-testid="catalog-filter"
        >
          <select name="active" class="select select-sm">
            <option value="true" selected={@active == "true"}>On sale</option>
            <option value="false" selected={@active == "false"}>Archived</option>
            <option value="" selected={@active == ""}>All</option>
          </select>
        </form>
      </div>

      <div class="overflow-x-auto rounded-box border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>Product</th>
              <th>Tax code</th>
              <th>State</th>
              <th></th>
            </tr>
          </thead>
          <tbody data-testid="catalog-rows">
            <tr :if={@stripe == []}>
              <td colspan="4" class="text-center opacity-70" data-testid="catalog-empty">
                {empty_text(@active)}
              </td>
            </tr>
            <tr
              :for={product <- @stripe}
              class="hover:bg-base-200 cursor-pointer"
              phx-click="open"
              phx-value-id={product.id}
              phx-target={@myself}
              data-testid="catalog-row"
              data-product-id={product.id}
            >
              <td>
                <div class="font-medium">{product.name}</div>
                <div class="text-xs opacity-60 font-mono">{product.id}</div>
              </td>
              <td class="font-mono text-xs">{product.tax_code || "–"}</td>
              <td>
                <span class={["badge badge-sm", (product.active && "badge-success") || "badge-ghost"]}>
                  {if product.active, do: "on sale", else: "archived"}
                </span>
              </td>
              <td class="text-xs opacity-60">prices ▾</td>
            </tr>
          </tbody>
        </table>
      </div>

      <button
        :if={@next}
        class="btn btn-sm btn-ghost"
        phx-click="more"
        phx-target={@myself}
        phx-disable-with="Asking Stripe..."
        data-testid="catalog-more"
      >
        Next {@page_size} from Stripe
      </button>

      <.product_card
        :for={product <- @stripe}
        :if={@open == product.id}
        product={product}
        prices={Map.get(@prices, product.id, [])}
        myself={@myself}
      />
    </section>
    """
  end

  attr :product, :map, required: true
  attr :prices, :list, required: true
  attr :myself, :any, required: true

  defp product_card(assigns) do
    ~H"""
    <div
      class="card bg-base-200 border border-primary/40"
      data-testid="catalog-product"
      data-product-id={@product.id}
    >
      <div class="card-body gap-3">
        <div class="flex flex-wrap items-center gap-3">
          <h3 class="card-title flex-1">{@product.name}</h3>
          <a
            href={"https://dashboard.stripe.com/test/products/#{@product.id}"}
            target="_blank"
            class="btn btn-ghost btn-sm"
            data-testid="catalog-stripe-link"
          >
            Stripe <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </a>
          <button
            :if={@product.active}
            class="btn btn-warning btn-outline btn-sm"
            phx-click="archive_product"
            phx-value-id={@product.id}
            phx-target={@myself}
            data-confirm="Archive this product? Past sales keep it; it goes off sale."
            data-testid="catalog-archive-product"
          >
            Archive product
          </button>
        </div>
        <.hint>MishkaPay.list_prices/3</.hint>
        <p :if={@prices == []} class="text-sm opacity-70" data-testid="catalog-prices-empty">
          No prices.
        </p>
        <ul class="space-y-1">
          <li
            :for={price <- @prices}
            class="flex flex-wrap items-center gap-2 text-sm"
            data-testid="catalog-price"
            data-price-id={price.id}
          >
            <span class="font-medium">{money(price)}</span>
            <code class="text-xs opacity-60">{price.id}</code>
            <code :if={price.lookup_key} class="text-xs">{price.lookup_key}</code>
            <span class={["badge badge-sm", (price.active && "badge-success") || "badge-ghost"]}>
              {if price.active, do: "on sale", else: "archived"}
            </span>
            <button
              :if={price.active}
              class="btn btn-xs"
              phx-click="archive_price"
              phx-value-id={price.id}
              phx-value-product_id={@product.id}
              phx-target={@myself}
              data-confirm="Archive this price? Checkouts can no longer sell it."
              data-testid="catalog-archive-price"
            >
              Archive price
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp first_page(socket), do: socket |> assign(stripe: [], page_size: @page) |> page(nil)

  # One more page of Stripe's products, added to those shown.
  defp page(socket, cursor) do
    opts = [limit: @page, after: cursor] ++ active(socket.assigns.active)

    case MishkaPay.list_products("stripe", socket.assigns.tenant, opts) do
      {:ok, %MishkaPay.Page{items: products, next: next}} ->
        assign(socket, stripe: socket.assigns.stripe ++ products, next: next)

      {:error, error} ->
        say(socket, :error, MishkaPay.Ash.message(error))
    end
  end

  defp empty_text("false"), do: "No archived products."
  defp empty_text("true"), do: "No product on sale yet. Publish the shop's products."
  defp empty_text(_all), do: "Stripe's catalog is empty. Publish the shop's products."

  defp active("true"), do: [active: true]
  defp active("false"), do: [active: false]
  defp active(_all), do: []

  defp load_prices(socket, product_id) do
    case MishkaPay.list_prices("stripe", socket.assigns.tenant, product_id: product_id, limit: 20) do
      {:ok, %MishkaPay.Page{items: prices}} ->
        assign(socket, prices: Map.put(socket.assigns.prices, product_id, prices))

      {:error, error} ->
        say(socket, :error, MishkaPay.Ash.message(error))
    end
  end

  defp money(%{amount: nil}), do: "–"

  defp money(%{amount: amount, interval: nil}), do: Money.to_string!(amount)

  defp money(%{amount: amount, interval: interval, interval_count: count}),
    do:
      "#{Money.to_string!(amount)} / #{if count in [nil, 1], do: interval, else: "#{count} #{interval}s"}"

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end
end

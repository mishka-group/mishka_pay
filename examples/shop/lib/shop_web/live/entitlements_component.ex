defmodule ShopWeb.EntitlementsComponent do
  @moduledoc """
  Entitlements, read live from Stripe: make a feature (`MishkaPay.create_feature/1`, a name and
  the lookup key a site checks access by), attach it to a catalog product
  (`MishkaPay.attach_feature/4`), and list what a customer may use now
  (`MishkaPay.list_entitlements/4`).
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, features: [], entitlements: nil, notice: nil, error: nil)}

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, tenant: assigns.tenant)}

  @impl true
  def handle_event("create_feature", params, socket) do
    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      name: params["name"],
      lookup_key: params["lookup_key"]
    }

    case MishkaPay.create_feature(attrs) do
      {:ok, feature} ->
        {:noreply,
         socket
         |> assign(features: [feature | socket.assigns.features])
         |> done("Feature #{feature.id} made. Attach it to a product to sell it.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  def handle_event("attach", %{"product_id" => product_id, "feature_id" => feature_id}, socket) do
    case MishkaPay.attach_feature(
           "stripe",
           String.trim(product_id),
           String.trim(feature_id),
           socket.assigns.tenant
         ) do
      {:ok, feature} ->
        {:noreply,
         done(socket, "#{feature.lookup_key} comes with #{String.trim(product_id)} now.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  def handle_event("entitlements", %{"customer_id" => customer_id}, socket) do
    case MishkaPay.list_entitlements("stripe", String.trim(customer_id), socket.assigns.tenant,
           limit: 20
         ) do
      {:ok, %MishkaPay.Page{items: entitlements}} ->
        {:noreply, socket |> assign(entitlements: entitlements, notice: nil, error: nil)}

      {:error, error} ->
        {:noreply, socket |> assign(entitlements: nil) |> failed(error)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="entitlements" class="space-y-4">
      <.section_title icon="hero-key" title="Entitlements" />
      <p class="text-sm opacity-70">
        A feature a product comes with. A customer who buys the product may use it: check access by
        its lookup key.
      </p>
      <.hint>MishkaPay.create_feature/1, attach_feature/4, list_entitlements/4</.hint>

      <div
        :if={@notice}
        role="status"
        class="alert alert-success py-2"
        data-testid="entitlements-notice"
      >
        {@notice}
      </div>
      <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="entitlements-error">
        {@error}
      </div>

      <div class="grid gap-4 lg:grid-cols-3">
        <form
          id="feature-form"
          phx-submit="create_feature"
          phx-target={@myself}
          class="card bg-base-200"
          data-testid="feature-form"
        >
          <div class="card-body gap-2">
            <h3 class="font-medium">New feature</h3>
            <label class="fieldset">
              <span class="fieldset-legend">Name</span>
              <input
                name="name"
                placeholder="Pro reports"
                class="input input-sm"
                data-testid="feature-name"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Lookup key</span>
              <input
                name="lookup_key"
                placeholder="pro-reports"
                class="input input-sm"
                data-testid="feature-key"
              />
            </label>
            <div>
              <button
                class="btn btn-sm btn-primary"
                phx-disable-with="Asking Stripe..."
                data-testid="feature-submit"
              >
                Make feature
              </button>
            </div>
            <ul :if={@features != []} class="text-sm space-y-1" data-testid="feature-rows">
              <li :for={feature <- @features} data-testid="feature-row" data-feature-id={feature.id}>
                <code>{feature.id}</code> {feature.lookup_key}
              </li>
            </ul>
          </div>
        </form>

        <form
          id="feature-attach-form"
          phx-submit="attach"
          phx-target={@myself}
          class="card bg-base-200"
          data-testid="feature-attach-form"
        >
          <div class="card-body gap-2">
            <h3 class="font-medium">Attach to a product</h3>
            <label class="fieldset">
              <span class="fieldset-legend">Product id</span>
              <input
                name="product_id"
                placeholder="prod_..."
                class="input input-sm"
                data-testid="feature-attach-product"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Feature id</span>
              <input
                name="feature_id"
                placeholder="feat_..."
                list="feature-ids"
                class="input input-sm"
                data-testid="feature-attach-feature"
              />
              <datalist id="feature-ids">
                <option :for={feature <- @features} value={feature.id} />
              </datalist>
            </label>
            <div>
              <button
                class="btn btn-sm"
                phx-disable-with="Asking Stripe..."
                data-testid="feature-attach-submit"
              >
                Attach
              </button>
            </div>
          </div>
        </form>

        <form
          id="entitlements-form"
          phx-submit="entitlements"
          phx-target={@myself}
          class="card bg-base-200"
          data-testid="entitlements-form"
        >
          <div class="card-body gap-2">
            <h3 class="font-medium">What a customer may use</h3>
            <label class="fieldset">
              <span class="fieldset-legend">v1 Customer id (Stripe takes no account here)</span>
              <input
                name="customer_id"
                placeholder="cus_..."
                class="input input-sm"
                data-testid="entitlements-customer"
              />
            </label>
            <div>
              <button
                class="btn btn-sm"
                phx-disable-with="Asking Stripe..."
                data-testid="entitlements-submit"
              >
                List
              </button>
            </div>
            <ul :if={@entitlements} class="text-sm space-y-1" data-testid="entitlement-rows">
              <li :if={@entitlements == []} class="opacity-70" data-testid="entitlements-empty">
                Nothing yet: this customer has bought no product with a feature.
              </li>
              <li
                :for={entitlement <- @entitlements}
                data-testid="entitlement-row"
                data-lookup-key={entitlement.lookup_key}
              >
                <span class="badge badge-success badge-sm">{entitlement.lookup_key}</span>
                <code class="text-xs opacity-70">{entitlement.feature_id}</code>
              </li>
            </ul>
          </div>
        </form>
      </div>
    </section>
    """
  end

  defp done(socket, message), do: assign(socket, notice: message, error: nil)

  defp failed(socket, error), do: assign(socket, error: MishkaPay.Ash.message(error), notice: nil)
end

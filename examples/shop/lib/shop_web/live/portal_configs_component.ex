defmodule ShopWeb.PortalConfigsComponent do
  @moduledoc """
  The customer portal's setups on Stripe, in the demo shop: what buyers may do there. It lists
  them a page at a time (`MishkaPay.list_portal_configurations/3`), makes one from a form
  (`MishkaPay.create_portal_configuration/1`: cancel mode, card and detail changes, bill history,
  the plans a buyer may switch to), turns one off or on (`MishkaPay.update_portal_configuration/1`),
  and opens the portal for a customer with the one picked (`MishkaPay.portal_session/1` with
  `configuration:`).

  Nothing is read when the page opens: "Show setups" reads the first page in the background and
  the shop's customers for the portal form, and each page after that is read only when asked.
  """

  use ShopWeb, :live_component

  require Ash.Query

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @open_form %{"customer" => "", "customer_id" => "", "configuration" => ""}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open?: false,
       reading?: false,
       configs: [],
       customers: [],
       next: nil,
       page: 0,
       form: %{"name" => "Teams", "subscription_cancel" => "at_period_end"},
       open_form: @open_form
     )}
  end

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, tenant: assigns.tenant)}

  @impl true
  def handle_event("show", _params, socket),
    do: {:noreply, socket |> assign(open?: true, page: 0, customers: customers()) |> read(nil)}

  def handle_event("next", _params, socket), do: {:noreply, read(socket, socket.assigns.next)}

  def handle_event("first", _params, socket),
    do: {:noreply, socket |> assign(page: 0) |> read(nil)}

  # Both forms keep what is typed or picked, so a page read or a setup turned off keeps it.
  def handle_event("draft_config", params, socket), do: {:noreply, assign(socket, form: params)}

  def handle_event("draft_open", params, socket),
    do: {:noreply, assign(socket, open_form: open_form(params))}

  def handle_event("create", params, socket) do
    socket = assign(socket, form: params)
    create(socket, params, blank_nil(params["name"]))
  end

  def handle_event("toggle", %{"id" => id, "active" => active}, socket) do
    attrs = %{provider: "stripe", tenant: socket.assigns.tenant, id: id, active: active != "true"}

    case MishkaPay.update_portal_configuration(attrs) do
      {:ok, config} ->
        {:noreply,
         socket
         |> update(:configs, fn configs ->
           Enum.map(configs, &if(&1.id == config.id, do: config, else: &1))
         end)
         |> say(:info, if(config.active, do: "Turned on.", else: "Turned off."))}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("open", %{"customer" => "", "customer_id" => ""} = params, socket) do
    {:noreply,
     socket
     |> assign(open_form: open_form(params))
     |> say(:error, "Pick a customer, or type its id (cus_...).")}
  end

  def handle_event("open", params, socket) do
    socket = assign(socket, open_form: open_form(params))

    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      customer_id: blank_nil(params["customer_id"]) || blank_nil(params["customer"]),
      configuration: blank_nil(params["configuration"]),
      return_url: url(~p"/?portal=back")
    }

    case MishkaPay.portal_session(Map.reject(attrs, fn {_key, value} -> is_nil(value) end)) do
      {:ok, session} -> {:noreply, redirect(socket, external: session.url)}
      {:error, error} -> {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  @impl true
  def handle_async(:page, {:ok, {:ok, %MishkaPay.Page{items: configs, next: next}}}, socket) do
    {:noreply,
     assign(socket, configs: configs, next: next, page: socket.assigns.page + 1, reading?: false)}
  end

  def handle_async(:page, {:ok, {:error, error}}, socket),
    do: {:noreply, socket |> read_failed() |> say(:error, MishkaPay.Ash.message(error))}

  def handle_async(:page, {:exit, reason}, socket),
    do: {:noreply, socket |> read_failed() |> say(:error, inspect(reason))}

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="portal-configs" class="space-y-4">
      <.section_title icon="hero-adjustments-horizontal" title="Customer portal setups" />
      <p class="text-sm opacity-70">
        What buyers may do on Stripe's portal page: one setup per kind of buyer, picked when the
        portal opens.
      </p>

      <button
        :if={!@open?}
        class="btn btn-sm"
        phx-click="show"
        phx-target={@myself}
        data-testid="portal-configs-show"
      >
        Show setups
      </button>

      <div :if={@open?} class="grid gap-4 md:grid-cols-2">
        <form
          id="portal-config-form"
          phx-change="draft_config"
          phx-submit="create"
          phx-target={@myself}
          class="rounded-box bg-base-200 p-4 space-y-2"
          data-testid="portal-config-form"
        >
          <.hint>MishkaPay.create_portal_configuration/1</.hint>
          <div class="grid gap-2 sm:grid-cols-2">
            <label class="fieldset">
              <span class="fieldset-legend">Name</span>
              <input
                name="name"
                value={@form["name"]}
                class="input input-sm"
                data-testid="portal-config-name"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Headline</span>
              <input
                name="headline"
                value={@form["headline"]}
                placeholder="up to 60 characters"
                class="input input-sm"
                data-testid="portal-config-headline"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Cancel a plan</span>
              <select
                name="subscription_cancel"
                class="select select-sm"
                data-testid="portal-config-cancel"
              >
                <option
                  :for={
                    {value, label} <- [
                      {"off", "Not allowed"},
                      {"at_period_end", "At the period's end"},
                      {"immediately", "At once"}
                    ]
                  }
                  value={value}
                  selected={@form["subscription_cancel"] == value}
                >
                  {label}
                </option>
              </select>
            </label>
            <fieldset class="fieldset">
              <span class="fieldset-legend">Buyers may</span>
              <label class="label text-sm">
                <input
                  type="checkbox"
                  name="invoice_history"
                  value="true"
                  class="checkbox checkbox-xs"
                  checked={@form["invoice_history"] == "true"}
                  data-testid="portal-config-invoices"
                /> see their bills
              </label>
              <label class="label text-sm">
                <input
                  type="checkbox"
                  name="payment_method_update"
                  value="true"
                  class="checkbox checkbox-xs"
                  checked={@form["payment_method_update"] == "true"}
                  data-testid="portal-config-card"
                /> change their card
              </label>
            </fieldset>
            <fieldset class="fieldset sm:col-span-2">
              <span class="fieldset-legend">Details they may change</span>
              <div class="flex flex-wrap gap-3">
                <label :for={field <- ~w(email name address phone tax_id)} class="label text-sm">
                  <input
                    type="checkbox"
                    name="customer_update[]"
                    value={field}
                    class="checkbox checkbox-xs"
                    checked={field in List.wrap(@form["customer_update"])}
                    data-testid={"portal-config-detail-#{field}"}
                  /> {field}
                </label>
              </div>
            </fieldset>
            <label class="fieldset">
              <span class="fieldset-legend">Switch to: product</span>
              <input
                name="product_id"
                value={@form["product_id"]}
                placeholder="prod_... (optional)"
                class="input input-sm"
                data-testid="portal-config-product"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">its prices</span>
              <input
                name="price_ids"
                value={@form["price_ids"]}
                placeholder="price_a, price_b"
                class="input input-sm"
                data-testid="portal-config-prices"
              />
            </label>
          </div>
          <button
            class="btn btn-sm btn-primary"
            phx-disable-with="Asking Stripe..."
            data-testid="portal-config-create"
          >
            Make this setup
          </button>
        </form>

        <form
          id="portal-open-form"
          phx-change="draft_open"
          phx-submit="open"
          phx-target={@myself}
          class="rounded-box bg-base-200 p-4 space-y-2"
          data-testid="portal-open-form"
        >
          <.hint>MishkaPay.portal_session/1 with configuration:</.hint>
          <label class="fieldset">
            <span class="fieldset-legend">Customer</span>
            <select name="customer" class="select select-sm" data-testid="portal-open-customer">
              <option value="" selected={@open_form["customer"] == ""}>Pick one</option>
              <option
                :for={customer <- @customers}
                value={customer.provider_id}
                selected={@open_form["customer"] == customer.provider_id}
              >
                {customer.name || customer.email || customer.provider_id}
              </option>
            </select>
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">or its id</span>
            <input
              name="customer_id"
              value={@open_form["customer_id"]}
              placeholder="cus_..."
              class="input input-sm"
              data-testid="portal-open-customer-id"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Setup</span>
            <select name="configuration" class="select select-sm" data-testid="portal-open-config">
              <option value="" selected={@open_form["configuration"] == ""}>Stripe's default</option>
              <option
                :for={config <- Enum.filter(@configs, & &1.active)}
                value={config.id}
                selected={@open_form["configuration"] == config.id}
              >
                {config.name || config.id}
              </option>
            </select>
          </label>
          <button
            class="btn btn-sm btn-primary"
            phx-disable-with="Asking Stripe..."
            data-testid="portal-open-submit"
          >
            Open the portal
          </button>
        </form>
      </div>

      <div :if={@open?} class="space-y-2" data-testid="portal-config-list">
        <div class="flex flex-wrap items-center gap-2 text-sm">
          <.hint>MishkaPay.list_portal_configurations/3</.hint>
          <span data-testid="portal-config-page">Page {@page}</span>
          <span
            :if={@reading?}
            class="loading loading-dots loading-xs"
            data-testid="portal-config-reading"
          ></span>
          <button
            :if={@page > 1}
            class="btn btn-xs"
            phx-click="first"
            phx-target={@myself}
            data-testid="portal-config-first"
          >
            First page
          </button>
          <button
            :if={@next && !@reading?}
            class="btn btn-xs btn-primary"
            phx-click="next"
            phx-target={@myself}
            data-testid="portal-config-next"
          >
            Next page
          </button>
        </div>
        <p
          :if={@configs == [] && !@reading?}
          class="text-sm opacity-70"
          data-testid="portal-config-empty"
        >
          No portal setups on Stripe yet: the portal uses Stripe's default.
        </p>
        <ul class="text-sm space-y-1">
          <li
            :for={config <- @configs}
            class="flex flex-wrap items-center gap-2 rounded-box bg-base-100 p-2"
            data-testid="portal-config-row"
            data-config-id={config.id}
            data-active={to_string(config.active)}
            data-default={to_string(config.default)}
          >
            <code class="text-xs">{config.id}</code>
            <span class="font-medium">{config.name || "–"}</span>
            <span :if={config.default} class="badge badge-xs badge-info">default</span>
            <span :if={!config.active} class="badge badge-xs">off</span>
            <span class="flex-1 text-xs opacity-70" data-testid="portal-config-summary">
              {summary(config)}
            </span>
            <button
              :if={!config.default}
              class="btn btn-xs"
              phx-click="toggle"
              phx-value-id={config.id}
              phx-value-active={to_string(config.active)}
              phx-target={@myself}
              data-testid="portal-config-toggle"
            >
              {if config.active, do: "Turn off", else: "Turn on"}
            </button>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  # One page from Stripe in the background, so the page stays live while Stripe answers.

  defp open_form(params), do: Map.merge(@open_form, Map.take(params, Map.keys(@open_form)))

  defp read(socket, cursor) do
    opts = Enum.reject([limit: 10, after: cursor], fn {_name, value} -> is_nil(value) end)
    tenant = socket.assigns.tenant

    socket
    |> assign(reading?: true)
    |> start_async(:page, fn -> MishkaPay.list_portal_configurations("stripe", tenant, opts) end)
  end

  # The shop names every setup it makes, so its list can tell them apart.
  defp create(socket, _params, nil),
    do: {:noreply, say(socket, :error, "Give the setup a name.")}

  defp create(socket, params, _name) do
    case MishkaPay.create_portal_configuration(config_attrs(params, socket.assigns.tenant)) do
      {:ok, config} ->
        {:noreply,
         socket
         |> update(:configs, &[config | &1])
         |> say(:info, "Portal setup #{config.id} made on Stripe.")}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  defp read_failed(socket), do: assign(socket, configs: [], next: nil, reading?: false)

  defp config_attrs(params, tenant) do
    %{
      provider: "stripe",
      tenant: tenant,
      name: blank_nil(params["name"]),
      headline: blank_nil(params["headline"]),
      subscription_cancel: params["subscription_cancel"],
      invoice_history: params["invoice_history"] == "true",
      payment_method_update: params["payment_method_update"] == "true",
      customer_update: List.wrap(params["customer_update"])
    }
    |> Map.merge(plans(params))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # A product with its prices lets buyers switch plans; without one, plans cannot change.
  defp plans(params) do
    prices =
      (params["price_ids"] || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case blank_nil(params["product_id"]) do
      nil ->
        %{subscription_update: []}

      product ->
        %{
          subscription_update: [:price],
          plans: [%{product_id: product, price_ids: prices}],
          proration: :create_prorations
        }
    end
  end

  defp summary(config) do
    [
      "cancel: #{config.subscription_cancel}",
      config.invoice_history && "bills",
      config.payment_method_update && "card",
      config.customer_update != [] && "details: #{Enum.join(config.customer_update, ", ")}",
      config.plans != [] &&
        "switch among #{config.plans |> Enum.flat_map(& &1.price_ids) |> length()} prices"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp customers do
    Shop.Pay.Customer
    |> Ash.Query.filter(is_nil(deleted_at))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(30)
    |> Ash.read!(authorize?: false)
  end

  defp blank_nil(value) do
    case String.trim(value || "") do
      "" -> nil
      text -> text
    end
  end

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end
end

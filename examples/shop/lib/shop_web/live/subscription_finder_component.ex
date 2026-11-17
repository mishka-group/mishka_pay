defmodule ShopWeb.SubscriptionFinderComponent do
  @moduledoc """
  Finds subscriptions on Stripe, beside the ones the shop keeps: a list by customer, price and
  status (`MishkaPay.list_subscriptions/3`), or Stripe's search by status, reference and metadata
  (`MishkaPay.search_subscriptions/3`), a page at a time with "Next page". "Open" keeps the one
  found in the shop (the subscriptions part's `read`, given as `open_target`) and shows it.
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [hint: 1]

  @statuses Enum.map(MishkaPay.Subscription.statuses(), &Atom.to_string/1)

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       statuses: @statuses,
       form: %{"mode" => "list", "status" => "", "limit" => "5"},
       items: [],
       next: nil,
       page: 0
     )}
  end

  @impl true
  def update(assigns, socket),
    do: {:ok, assign(socket, tenant: assigns.tenant, open_target: assigns.open_target)}

  @impl true
  def handle_event("find", params, socket) do
    {:noreply, socket |> assign(form: params, page: 0) |> read(nil)}
  end

  def handle_event("next", _params, socket), do: {:noreply, read(socket, socket.assigns.next)}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="rounded-box bg-base-200 p-4 space-y-3" data-testid="subscription-finder">
      <h4 class="font-medium">Find subscriptions on Stripe</h4>
      <.hint>MishkaPay.list_subscriptions/3 and MishkaPay.search_subscriptions/3</.hint>
      <form
        phx-submit="find"
        phx-target={@myself}
        class="grid gap-2 sm:grid-cols-3 lg:grid-cols-6 items-end"
        data-testid="sub-finder-form"
      >
        <label class="fieldset">
          <span class="fieldset-legend">How</span>
          <select name="mode" class="select select-sm" data-testid="sub-finder-mode">
            <option value="list" selected={@form["mode"] == "list"}>
              List (customer, price, status)
            </option>
            <option value="search" selected={@form["mode"] == "search"}>
              Search (status, reference, metadata)
            </option>
          </select>
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">Status</span>
          <select name="status" class="select select-sm" data-testid="sub-finder-status">
            <option value="" selected={@form["status"] == ""}>Any but ended</option>
            <option value="all" selected={@form["status"] == "all"}>All, ended too (list)</option>
            <option :for={status <- @statuses} value={status} selected={@form["status"] == status}>
              {status}
            </option>
          </select>
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">Customer (list)</span>
          <input
            name="customer_id"
            value={@form["customer_id"]}
            placeholder="cus_..."
            class="input input-sm"
            data-testid="sub-finder-customer"
          />
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">Price (list)</span>
          <input
            name="price_id"
            value={@form["price_id"]}
            placeholder="price_..."
            class="input input-sm"
            data-testid="sub-finder-price"
          />
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">Reference (search)</span>
          <input
            name="reference"
            value={@form["reference"]}
            placeholder="the checkout's reference"
            class="input input-sm"
            data-testid="sub-finder-reference"
          />
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">Metadata (search)</span>
          <input
            name="metadata"
            value={@form["metadata"]}
            placeholder="key=value"
            class="input input-sm"
            data-testid="sub-finder-metadata"
          />
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">A page holds</span>
          <select name="limit" class="select select-sm" data-testid="sub-finder-limit">
            <option :for={n <- ~w(1 2 5 10 25)} value={n} selected={n == @form["limit"]}>{n}</option>
          </select>
        </label>
        <button
          class="btn btn-sm btn-primary"
          phx-disable-with="Asking Stripe..."
          data-testid="sub-finder-submit"
        >
          Find
        </button>
      </form>

      <div
        :if={@page > 0}
        class="flex flex-wrap items-center gap-2 text-sm"
        data-testid="sub-finder-pager"
      >
        <span data-testid="sub-finder-page">Page {@page}</span>
        <span class="opacity-60">· {length(@items)} on it</span>
        <button
          :if={@next}
          class="btn btn-xs btn-primary"
          phx-click="next"
          phx-target={@myself}
          phx-disable-with="Asking Stripe..."
          data-testid="sub-finder-next"
        >
          Next page
        </button>
        <span :if={!@next} class="opacity-60" data-testid="sub-finder-last">last page</span>
        <span :if={@form["mode"] == "search"} class="opacity-60">
          Stripe's search finds a new subscription after about a minute.
        </span>
      </div>

      <div :if={@page > 0} class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
        <table class="table table-sm">
          <tbody data-testid="sub-finder-rows">
            <tr :if={@items == []}>
              <td class="opacity-70" data-testid="sub-finder-empty">
                No subscription on Stripe matches.
              </td>
            </tr>
            <tr
              :for={sub <- @items}
              data-testid="sub-finder-row"
              data-subscription-id={sub.id}
              data-status={sub.status}
            >
              <td class="font-mono text-xs">{sub.id}</td>
              <td><span class="badge badge-sm">{sub.status}</span></td>
              <td class="text-xs break-all">{sub.customer_email || sub.customer_id}</td>
              <td class="text-xs">{plan(sub)}</td>
              <td class="text-xs font-mono">{sub.reference}</td>
              <td>
                <button
                  class="btn btn-xs"
                  phx-click="read"
                  phx-value-subscription_id={sub.id}
                  phx-target={@open_target}
                  data-testid="sub-finder-open"
                >
                  Open
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp read(socket, cursor) do
    %{form: form, tenant: tenant} = socket.assigns

    case find(form, tenant, cursor) do
      {:ok, %MishkaPay.Page{items: items, next: next}} ->
        assign(socket, items: items, next: next, page: socket.assigns.page + 1)

      {:error, error} ->
        send(self(), {:flash, :error, MishkaPay.Ash.message(error)})
        assign(socket, items: [], next: nil, page: 0)
    end
  end

  defp find(%{"mode" => "search"} = form, tenant, cursor) do
    opts = [status: status(form), reference: text(form["reference"]), metadata: pair(form)]
    MishkaPay.search_subscriptions("stripe", tenant, paged(opts, form, cursor))
  end

  defp find(form, tenant, cursor) do
    opts = [
      status: status(form),
      customer_id: text(form["customer_id"]),
      price_id: text(form["price_id"])
    ]

    MishkaPay.list_subscriptions("stripe", tenant, paged(opts, form, cursor))
  end

  defp paged(opts, form, cursor) do
    opts
    |> Keyword.merge(limit: String.to_integer(form["limit"] || "5"), after: cursor)
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
  end

  # A status from the form: one a subscription has, or `all`; anything else goes as typed, for
  # Mishka Pay to refuse.
  defp status(%{"status" => "all"}), do: :all
  defp status(%{"status" => status}) when status in @statuses, do: String.to_existing_atom(status)
  defp status(_any), do: nil

  defp pair(form) do
    case String.split(form["metadata"] || "", "=", parts: 2) do
      [key, value] when key != "" -> %{String.trim(key) => String.trim(value)}
      _none -> nil
    end
  end

  defp text(value) do
    case String.trim(value || "") do
      "" -> nil
      text -> text
    end
  end

  defp plan(%{items: [item | _]}) do
    amount = if item.amount, do: Money.to_string!(item.amount), else: "–"
    "#{item.name || item.product_id} · #{amount} / #{item.interval || "once"}"
  end

  defp plan(_none), do: "–"
end

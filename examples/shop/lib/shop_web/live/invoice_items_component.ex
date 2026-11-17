defmodule ShopWeb.InvoiceItemsComponent do
  @moduledoc """
  Charges kept for a customer's next bill, in the bills part of the demo shop: add a pending item
  (`MishkaPay.create_invoice_item/1`, each with its own reference, which makes Stripe's
  idempotency key), list
  what waits for the customer (`MishkaPay.list_invoice_items/3` with `pending: true`, a page at a
  time), add one more of an item (`MishkaPay.update_invoice_item/1`) or take it back
  (`MishkaPay.delete_invoice_item/3`). A one-off bill or a renewal picks them up.
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [hint: 1]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       customer_id: nil,
       items: [],
       next: nil,
       page: 0,
       form: %{"name" => "Setup fee", "amount" => "49.00", "currency" => "USD", "quantity" => "1"}
     )}
  end

  @impl true
  def update(assigns, socket),
    do: {:ok, assign(socket, tenant: assigns.tenant, customers: assigns.customers)}

  @impl true
  def handle_event("add", params, socket) do
    socket = assign(socket, form: params)

    with {:ok, customer_id} <- customer_id(params),
         {:ok, item} <- MishkaPay.create_invoice_item(attrs(customer_id, params, socket)) do
      {:noreply,
       socket
       |> assign(customer_id: customer_id, page: 0)
       |> read(nil)
       |> say(:info, "#{item.name} waits for #{customer_id}'s next bill.")}
    else
      {:error, error} -> {:noreply, refused(socket, error)}
    end
  end

  # The form keeps what was typed, so "Show waiting" reads the customer picked there.
  def handle_event("draft", params, socket), do: {:noreply, assign(socket, form: params)}

  def handle_event("show", _params, socket) do
    case customer_id(socket.assigns.form) do
      {:ok, customer_id} ->
        {:noreply, socket |> assign(customer_id: customer_id, page: 0) |> read(nil)}

      {:error, error} ->
        {:noreply, refused(socket, error)}
    end
  end

  def handle_event("next", _params, socket), do: {:noreply, read(socket, socket.assigns.next)}

  def handle_event("more", %{"id" => id, "quantity" => quantity}, socket) do
    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      id: id,
      quantity: String.to_integer(quantity) + 1
    }

    case MishkaPay.update_invoice_item(attrs) do
      {:ok, item} -> {:noreply, socket |> replace(item) |> say(:info, "Now #{item.quantity}.")}
      {:error, error} -> {:noreply, refused(socket, error)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case MishkaPay.delete_invoice_item("stripe", id, socket.assigns.tenant) do
      :ok ->
        {:noreply,
         socket
         |> update(:items, fn items -> Enum.reject(items, &(&1.id == id)) end)
         |> say(:info, "Taken back: it will not be billed.")}

      {:error, error} ->
        {:noreply, refused(socket, error)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="rounded-box bg-base-200 p-4 space-y-3" data-testid="invoice-items">
      <h4 class="font-medium">Charges for the next bill</h4>
      <.hint>
        MishkaPay.create_invoice_item/1, list_invoice_items/3 (pending: true),
        update_invoice_item/1, delete_invoice_item/3
      </.hint>
      <form
        id="invoice-item-form"
        phx-change="draft"
        phx-submit="add"
        phx-target={@myself}
        class="grid gap-2 sm:grid-cols-3 lg:grid-cols-6 items-end"
        data-testid="invoice-item-form"
      >
        <label class="fieldset">
          <span class="fieldset-legend">Customer</span>
          <select name="customer" class="select select-sm" data-testid="invoice-item-customer">
            <option value="">Pick one</option>
            <option
              :for={customer <- @customers}
              value={customer.provider_id}
              selected={@form["customer"] == customer.provider_id}
            >
              {customer.name || customer.email || customer.provider_id}
            </option>
          </select>
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">or its id</span>
          <input
            name="customer_id"
            value={@form["customer_id"]}
            placeholder="cus_..."
            class="input input-sm"
            data-testid="invoice-item-customer-id"
          />
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">What it charges</span>
          <input
            name="name"
            value={@form["name"]}
            class="input input-sm"
            data-testid="invoice-item-name"
          />
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">Price of one</span>
          <div class="join">
            <input
              name="amount"
              value={@form["amount"]}
              class="input input-sm join-item w-24"
              data-testid="invoice-item-amount"
            />
            <select
              name="currency"
              class="select select-sm join-item"
              data-testid="invoice-item-currency"
            >
              <option :for={c <- ~w(USD EUR GBP)} value={c} selected={@form["currency"] == c}>
                {c}
              </option>
            </select>
          </div>
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">Quantity</span>
          <input
            name="quantity"
            type="number"
            min="1"
            value={@form["quantity"]}
            class="input input-sm w-20"
            data-testid="invoice-item-quantity"
          />
        </label>
        <div class="flex gap-2">
          <button
            class="btn btn-sm btn-primary"
            phx-disable-with="Asking Stripe..."
            data-testid="invoice-item-add"
          >
            Add pending item
          </button>
          <button
            type="button"
            class="btn btn-sm"
            phx-click="show"
            phx-target={@myself}
            data-testid="invoice-item-show"
          >
            Show waiting
          </button>
        </div>
      </form>

      <div :if={@page > 0} class="space-y-2" data-testid="invoice-item-list">
        <div class="flex flex-wrap items-center gap-2 text-sm">
          <span data-testid="invoice-item-page">Page {@page}</span>
          <span class="opacity-60">· waiting for {@customer_id}'s next bill</span>
          <button
            :if={@next}
            class="btn btn-xs btn-primary"
            phx-click="next"
            phx-target={@myself}
            data-testid="invoice-item-next"
          >
            Next page
          </button>
        </div>
        <p :if={@items == []} class="text-sm opacity-70" data-testid="invoice-item-empty">
          Nothing waits for this customer's next bill.
        </p>
        <ul class="text-sm space-y-1">
          <li
            :for={item <- @items}
            class="flex flex-wrap items-center gap-2"
            data-testid="invoice-item-row"
            data-item-id={item.id}
          >
            <code class="text-xs">{item.id}</code>
            <span class="flex-1">{item.name || item.price_id}</span>
            <span data-testid="invoice-item-row-quantity">× {item.quantity}</span>
            <span class="font-mono" data-testid="invoice-item-row-total">{money(item.total)}</span>
            <button
              class="btn btn-xs"
              phx-click="more"
              phx-value-id={item.id}
              phx-value-quantity={item.quantity || 1}
              phx-target={@myself}
              data-testid="invoice-item-more"
            >
              One more
            </button>
            <button
              class="btn btn-xs btn-error btn-outline"
              phx-click="delete"
              phx-value-id={item.id}
              phx-target={@myself}
              data-confirm="Take this charge back? It will not be billed."
              data-testid="invoice-item-delete"
            >
              Take back
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp attrs(customer_id, params, socket) do
    %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      customer_id: customer_id,
      name: params["name"],
      amount: %{amount: params["amount"], currency: params["currency"]},
      quantity: quantity(params["quantity"]),
      reference: "item-" <> Ecto.UUID.generate()
    }
  end

  defp read(socket, cursor) do
    %{customer_id: customer_id, tenant: tenant} = socket.assigns
    opts = [customer_id: customer_id, pending: true, limit: 10, after: cursor]

    case MishkaPay.list_invoice_items("stripe", tenant, Enum.reject(opts, &is_nil(elem(&1, 1)))) do
      {:ok, %MishkaPay.Page{items: items, next: next}} ->
        assign(socket, items: items, next: next, page: socket.assigns.page + 1)

      {:error, error} ->
        socket |> assign(items: [], next: nil, page: 0) |> refused(error)
    end
  end

  defp replace(socket, item) do
    update(socket, :items, fn items ->
      Enum.map(items, fn row -> if row.id == item.id, do: item, else: row end)
    end)
  end

  defp customer_id(params) do
    case blank_nil(params["customer_id"]) || blank_nil(params["customer"]) do
      nil -> {:error, "Pick a customer, or type its id (cus_...)."}
      id -> {:ok, id}
    end
  end

  defp quantity(value) do
    case Integer.parse(String.trim(value || "")) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp blank_nil(value) do
    case String.trim(value || "") do
      "" -> nil
      text -> text
    end
  end

  defp money(nil), do: "–"
  defp money(money), do: Money.to_string!(money)

  defp refused(socket, error) do
    message = if is_binary(error), do: error, else: MishkaPay.Ash.message(error)
    say(socket, :error, message)
  end

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end
end

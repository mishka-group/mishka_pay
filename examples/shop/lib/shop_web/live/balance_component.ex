defmodule ShopWeb.BalanceComponent do
  @moduledoc """
  Money held at Stripe, read live: the seller's balance, available and pending per currency
  (`MishkaPay.fetch_balance/2`), its movements page by page
  (`MishkaPay.list_balance_transactions/3`), and a customer's own balance: give credit taken off
  their next bills or add a debit (`MishkaPay.adjust_customer_balance/5`), and list its changes
  (`MishkaPay.list_customer_balance/4`).
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       balance: nil,
       movements: nil,
       movements_next: nil,
       customer_id: "",
       customer_balance: nil,
       notice: nil,
       error: nil
     )}
  end

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, tenant: assigns.tenant)}

  @impl true
  def handle_event("balance", _params, socket) do
    case MishkaPay.fetch_balance("stripe", socket.assigns.tenant) do
      {:ok, balance} -> {:noreply, assign(socket, balance: balance, notice: nil, error: nil)}
      {:error, error} -> {:noreply, failed(socket, error)}
    end
  end

  def handle_event("movements", _params, socket),
    do: {:noreply, socket |> assign(movements: []) |> movements(nil)}

  def handle_event("more_movements", _params, socket),
    do: {:noreply, movements(socket, socket.assigns.movements_next)}

  def handle_event("customer_balance", %{"intent" => "list", "customer_id" => id}, socket) do
    {:noreply,
     socket |> assign(customer_id: String.trim(id), notice: nil, error: nil) |> customer_balance()}
  end

  def handle_event("customer_balance", %{"customer_id" => id} = params, socket) do
    customer_id = String.trim(id)
    amount = String.trim(params["amount"] || "")
    signed = if params["direction"] == "credit", do: "-" <> amount, else: amount

    opts = [
      description: blank(params["description"]),
      reference: "adjust-#{System.unique_integer([:positive])}"
    ]

    case MishkaPay.adjust_customer_balance(
           "stripe",
           customer_id,
           %{amount: signed, currency: params["currency"]},
           socket.assigns.tenant,
           opts
         ) do
      {:ok, change} ->
        {:noreply,
         socket
         |> assign(customer_id: customer_id)
         |> customer_balance()
         |> done("Balance changed. #{customer_id} now has #{money(change.ending_balance)}.")}

      {:error, error} ->
        {:noreply, socket |> assign(customer_id: customer_id) |> failed(error)}
    end
  end

  defp movements(socket, after_id) do
    case MishkaPay.list_balance_transactions("stripe", socket.assigns.tenant,
           limit: 10,
           after: after_id
         ) do
      {:ok, page} ->
        assign(socket,
          movements: socket.assigns.movements ++ page.items,
          movements_next: page.has_more && page.next,
          notice: nil,
          error: nil
        )

      {:error, error} ->
        failed(socket, error)
    end
  end

  defp customer_balance(%{assigns: %{customer_id: ""}} = socket),
    do: assign(socket, error: "Give a customer id (cus_...).", notice: nil)

  defp customer_balance(socket) do
    %{customer_id: customer_id, tenant: tenant} = socket.assigns

    case MishkaPay.list_customer_balance("stripe", customer_id, tenant, limit: 10) do
      {:ok, page} -> assign(socket, customer_balance: page.items)
      {:error, error} -> socket |> assign(customer_balance: nil) |> failed(error)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="balance" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <.section_title icon="hero-scale" title="Balances" />
        <div class="flex gap-2">
          <button
            class="btn btn-sm"
            phx-click="balance"
            phx-target={@myself}
            phx-disable-with="Asking Stripe..."
            data-testid="balance-read"
          >
            Read balance
          </button>
          <button
            class="btn btn-sm"
            phx-click="movements"
            phx-target={@myself}
            phx-disable-with="Asking Stripe..."
            data-testid="balance-movements"
          >
            Balance movements
          </button>
        </div>
      </div>
      <.hint>
        MishkaPay.fetch_balance/2, list_balance_transactions/3, adjust_customer_balance/5, list_customer_balance/4
      </.hint>

      <div :if={@notice} role="status" class="alert alert-success py-2" data-testid="balance-notice">
        {@notice}
      </div>
      <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="balance-error">
        {@error}
      </div>

      <div :if={@balance} class="grid gap-4 sm:grid-cols-2" data-testid="balance-result">
        <div class="card bg-base-200">
          <div class="card-body gap-1">
            <h3 class="font-medium">Available</h3>
            <p
              :for={amount <- @balance.available}
              class="text-lg font-semibold"
              data-testid="balance-available"
            >
              {money(amount)}
            </p>
            <p :if={@balance.available == []} class="opacity-70" data-testid="balance-available">
              Nothing yet.
            </p>
          </div>
        </div>
        <div class="card bg-base-200">
          <div class="card-body gap-1">
            <h3 class="font-medium">Pending</h3>
            <p
              :for={amount <- @balance.pending}
              class="text-lg font-semibold"
              data-testid="balance-pending"
            >
              {money(amount)}
            </p>
            <p :if={@balance.pending == []} class="opacity-70" data-testid="balance-pending">
              Nothing yet.
            </p>
          </div>
        </div>
      </div>

      <div :if={@movements} class="overflow-x-auto rounded-box border border-base-300">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Movement</th>
              <th>Kind</th>
              <th>Amount</th>
              <th>Fee</th>
              <th>Net</th>
              <th>State</th>
            </tr>
          </thead>
          <tbody data-testid="balance-movement-rows">
            <tr :if={@movements == []}>
              <td colspan="6" class="text-center opacity-70" data-testid="balance-movements-empty">
                No movements.
              </td>
            </tr>
            <tr :for={txn <- @movements} data-testid="balance-movement-row" data-movement-id={txn.id}>
              <td class="font-mono text-xs">{txn.id}</td>
              <td>{txn.type}</td>
              <td>{money(txn.amount)}</td>
              <td>{money(txn.fee)}</td>
              <td data-testid="balance-movement-net">{money(txn.net)}</td>
              <td>{txn.status}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <button
        :if={@movements_next}
        class="btn btn-sm btn-ghost"
        phx-click="more_movements"
        phx-target={@myself}
        phx-disable-with="Asking Stripe..."
        data-testid="balance-movements-more"
      >
        More movements
      </button>

      <form
        id="customer-balance-form"
        phx-submit="customer_balance"
        phx-target={@myself}
        class="card bg-base-200"
        data-testid="customer-balance-form"
      >
        <div class="card-body gap-3">
          <h3 class="font-medium">A customer's balance</h3>
          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
            <label class="fieldset">
              <span class="fieldset-legend">Customer id</span>
              <input
                name="customer_id"
                value={@customer_id}
                placeholder="cus_..."
                class="input input-sm"
                data-testid="customer-balance-customer"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Give</span>
              <select
                name="direction"
                class="select select-sm"
                data-testid="customer-balance-direction"
              >
                <option value="credit">Credit (off next bills)</option>
                <option value="debit">Debit (added to next bill)</option>
              </select>
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Amount</span>
              <input
                name="amount"
                value="5.00"
                type="number"
                step="0.01"
                min="0.01"
                class="input input-sm"
                data-testid="customer-balance-amount"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Currency</span>
              <select name="currency" class="select select-sm" data-testid="customer-balance-currency">
                <option value="USD">USD</option>
                <option value="EUR">EUR</option>
              </select>
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Why</span>
              <input
                name="description"
                placeholder="Sorry for the wait"
                class="input input-sm"
                data-testid="customer-balance-description"
              />
            </label>
          </div>
          <div class="flex gap-2">
            <button
              name="intent"
              value="adjust"
              class="btn btn-sm btn-primary"
              phx-disable-with="Asking Stripe..."
              data-testid="customer-balance-adjust"
            >
              Change balance
            </button>
            <button name="intent" value="list" class="btn btn-sm" data-testid="customer-balance-list">
              List changes
            </button>
          </div>
          <ul :if={@customer_balance} class="text-sm space-y-1" data-testid="customer-balance-rows">
            <li :if={@customer_balance == []} class="opacity-70" data-testid="customer-balance-empty">
              No changes yet.
            </li>
            <li
              :for={change <- @customer_balance}
              data-testid="customer-balance-row"
              data-change-id={change.id}
            >
              <span class="font-medium">{money(change.amount)}</span>
              then {money(change.ending_balance)}
              <span :if={change.description} class="opacity-70">· {change.description}</span>
            </li>
          </ul>
        </div>
      </form>
    </section>
    """
  end

  defp money(%Money{} = money), do: Money.to_string!(money)
  defp money(_none), do: "–"

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank(_none), do: nil

  defp done(socket, message), do: assign(socket, notice: message, error: nil)

  defp failed(socket, error), do: assign(socket, error: MishkaPay.Ash.message(error), notice: nil)
end

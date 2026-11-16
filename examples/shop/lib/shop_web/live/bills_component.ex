defmodule ShopWeb.BillsComponent do
  @moduledoc """
  One-off bills in the demo shop, outside any subscription: `MishkaPay.create_invoice/1` makes a
  draft for a customer with its items, then each step is one button: finalize
  (`finalize_invoice/3`), email it (`send_invoice/3`), mark it paid by other means
  (`pay_invoice/4` with `out_of_band: true`), void it, mark it uncollectible, or delete a draft.
  After each step the bill shows its status, number, and Stripe's page and PDF.

  Stripe sells as merchant of record only through checkouts and payment links: with merchant of
  record on, Stripe refuses a one-off bill, and the page says so.
  """

  use ShopWeb, :live_component

  require Ash.Query

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       bill: nil,
       deleted: nil,
       steps: [],
       error: nil,
       form: %{
         "item_name" => "Consulting, one hour",
         "item_amount" => "120.00",
         "item_quantity" => "1",
         "collection" => "send_invoice"
       }
     )}
  end

  @impl true
  def update(assigns, socket),
    do: {:ok, assign(socket, tenant: assigns.tenant, customers: customers())}

  @impl true
  # The form keeps what was typed, so a refused bill can be fixed instead of typed again.
  def handle_event("draft", params, socket), do: {:noreply, assign(socket, form: params)}

  def handle_event("create", params, socket) do
    socket = assign(socket, form: params, error: nil)

    with {:ok, customer_id} <- customer_id(params),
         {:ok, bill} <-
           MishkaPay.create_invoice(draft(customer_id, params, socket.assigns.tenant)) do
      {:noreply,
       socket
       |> assign(bill: bill, deleted: nil, steps: [])
       |> step("Made as a draft", bill)}
    else
      {:error, error} -> {:noreply, refused(socket, error)}
    end
  end

  def handle_event("read", %{"bill_id" => id}, socket) do
    case MishkaPay.fetch_invoice("stripe", String.trim(id), socket.assigns.tenant) do
      {:ok, bill} ->
        {:noreply,
         socket
         |> assign(bill: bill, deleted: nil, error: nil, steps: [])
         |> step("Read again", bill)}

      {:error, error} ->
        {:noreply, refused(socket, error)}
    end
  end

  def handle_event("step", %{"do" => action}, %{assigns: %{bill: %{id: id}}} = socket) do
    case call(action, id, socket.assigns.tenant) do
      :ok ->
        {:noreply,
         socket
         |> assign(bill: nil, deleted: id)
         |> update(:steps, &[%{label: "Deleted", status: :deleted} | &1])
         |> say(:info, "Draft bill deleted.")}

      {:ok, bill} ->
        {:noreply, socket |> assign(bill: bill) |> step(done(action), bill)}

      {:error, error} ->
        {:noreply, refused(socket, error)}
    end
  end

  def handle_event("step", _params, socket),
    do: {:noreply, say(socket, :error, "Make a bill first.")}

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="bills" class="space-y-4">
      <.section_title icon="hero-document-text" title="One-off bills" />
      <p class="text-sm opacity-70">
        A bill for a customer, outside any plan: make it, open it, email it, mark it paid, or end it.
        Stripe refuses one-off bills while merchant of record is on.
      </p>

      <div class="grid gap-4 md:grid-cols-2">
        <form
          id="bill-form"
          phx-change="draft"
          phx-submit="create"
          phx-target={@myself}
          class="rounded-box bg-base-200 p-4 space-y-3"
          data-testid="bill-form"
        >
          <.hint>MishkaPay.create_invoice/1</.hint>
          <div class="grid gap-2 sm:grid-cols-2">
            <label class="fieldset">
              <span class="fieldset-legend">Customer</span>
              <select name="customer" class="select select-sm" data-testid="bill-customer">
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
                data-testid="bill-customer-id"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">What it bills</span>
              <input
                name="item_name"
                value={@form["item_name"]}
                class="input input-sm"
                data-testid="bill-item-name"
              />
            </label>
            <div class="grid grid-cols-2 gap-2">
              <label class="fieldset">
                <span class="fieldset-legend">Price, USD</span>
                <input
                  name="item_amount"
                  value={@form["item_amount"]}
                  class="input input-sm"
                  data-testid="bill-item-amount"
                />
              </label>
              <label class="fieldset">
                <span class="fieldset-legend">Quantity</span>
                <input
                  name="item_quantity"
                  type="number"
                  min="1"
                  value={@form["item_quantity"]}
                  class="input input-sm"
                  data-testid="bill-item-quantity"
                />
              </label>
            </div>
            <label class="fieldset">
              <span class="fieldset-legend">How it is paid</span>
              <select name="collection" class="select select-sm" data-testid="bill-collection">
                <option value="send_invoice" selected={@form["collection"] == "send_invoice"}>
                  Email it, the customer pays on Stripe's page
                </option>
                <option
                  value="charge_automatically"
                  selected={@form["collection"] == "charge_automatically"}
                >
                  Charge the saved card
                </option>
              </select>
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Days to pay (emailed bills)</span>
              <input
                name="days_until_due"
                value={@form["days_until_due"]}
                type="number"
                min="1"
                placeholder="30"
                class="input input-sm"
                data-testid="bill-days"
              />
            </label>
            <label class="fieldset sm:col-span-2">
              <span class="fieldset-legend">Note on the bill</span>
              <input
                name="description"
                value={@form["description"]}
                placeholder="Thank you for your order."
                class="input input-sm"
                data-testid="bill-description"
              />
            </label>
          </div>
          <button
            class="btn btn-sm btn-primary"
            phx-disable-with="Asking Stripe..."
            data-testid="bill-create"
          >
            Make the bill
          </button>
          <p :if={@error} class="alert alert-error text-sm" data-testid="bill-error">{@error}</p>
        </form>

        <div class="rounded-box bg-base-200 p-4 space-y-3" data-testid="bill-result">
          <form
            id="bill-lookup"
            phx-submit="read"
            phx-target={@myself}
            class="join"
            data-testid="bill-lookup"
          >
            <input
              name="bill_id"
              placeholder="in_... a bill made before"
              required
              class="input input-sm join-item"
              data-testid="bill-lookup-id"
            />
            <button class="btn btn-sm join-item" data-testid="bill-lookup-submit">Read it</button>
          </form>
          <p
            :if={!@bill and !@deleted}
            class="text-sm opacity-70"
            data-testid="bill-none"
          >
            No bill yet. Make one on the left.
          </p>
          <p :if={@deleted} class="text-sm" data-testid="bill-deleted">
            Bill <code>{@deleted}</code> was a draft and is deleted.
          </p>
          <.bill :if={@bill} bill={@bill} myself={@myself} />
          <ol :if={@steps != []} class="text-xs space-y-1 border-t border-base-300 pt-2">
            <li
              :for={step <- Enum.reverse(@steps)}
              data-testid="bill-step"
              data-status={step.status}
            >
              {step.label}: <span class="badge badge-xs">{step.status}</span>
            </li>
          </ol>
        </div>
      </div>
    </section>
    """
  end

  attr :bill, :map, required: true
  attr :myself, :any, required: true

  defp bill(assigns) do
    ~H"""
    <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm" data-testid="bill-card">
      <dt class="opacity-70">Bill</dt>
      <dd class="font-mono text-xs break-all" data-testid="bill-id">{@bill.id}</dd>
      <dt class="opacity-70">Status</dt>
      <dd data-testid="bill-status"><span class="badge badge-sm">{@bill.status}</span></dd>
      <dt class="opacity-70">Number</dt>
      <dd data-testid="bill-number">{@bill.number || "given when finalized"}</dd>
      <dt class="opacity-70">Due</dt>
      <dd data-testid="bill-due">{money(@bill.amount_due)}</dd>
      <dt class="opacity-70">Paid</dt>
      <dd>{money(@bill.amount_paid)}</dd>
      <dt class="opacity-70">Links</dt>
      <dd class="flex gap-3">
        <a
          :if={@bill.hosted_url}
          href={@bill.hosted_url}
          target="_blank"
          class="link"
          data-testid="bill-hosted-link"
        >
          Stripe's page
        </a>
        <a
          :if={@bill.pdf_url}
          href={@bill.pdf_url}
          target="_blank"
          class="link"
          data-testid="bill-pdf-link"
        >
          PDF
        </a>
        <span :if={!@bill.hosted_url and !@bill.pdf_url} class="opacity-60">
          once finalized
        </span>
      </dd>
    </dl>
    <div class="flex flex-wrap gap-2" data-testid="bill-actions">
      <.step_button
        :if={@bill.status == :draft}
        action="finalize"
        myself={@myself}
        class="btn-primary"
      >
        Finalize
      </.step_button>
      <.step_button
        :if={@bill.status == :open and @bill.collection == :send_invoice}
        action="send"
        myself={@myself}
        class=""
      >
        Email it
      </.step_button>
      <.step_button
        :if={@bill.status in [:open, :uncollectible]}
        action="pay_out_of_band"
        myself={@myself}
        class="btn-success"
      >
        Paid by other means
      </.step_button>
      <.step_button
        :if={@bill.status == :open}
        action="uncollectible"
        myself={@myself}
        class="btn-warning"
      >
        Mark uncollectible
      </.step_button>
      <.step_button
        :if={@bill.status in [:open, :uncollectible]}
        action="void"
        myself={@myself}
        class="btn-error btn-outline"
        confirm="Void this bill? It stays on record and can no longer be paid."
      >
        Void
      </.step_button>
      <.step_button
        :if={@bill.status == :draft}
        action="delete"
        myself={@myself}
        class="btn-error btn-outline"
        confirm="Delete this draft bill?"
      >
        Delete draft
      </.step_button>
      <.step_button action="read" myself={@myself} class="btn-ghost">
        <.icon name="hero-arrow-path" class="size-4" /> Read again
      </.step_button>
    </div>
    """
  end

  attr :action, :string, required: true
  attr :myself, :any, required: true
  attr :class, :string, required: true
  attr :confirm, :string, default: nil
  slot :inner_block, required: true

  defp step_button(assigns) do
    ~H"""
    <button
      class={["btn btn-sm", @class]}
      phx-click="step"
      phx-value-do={@action}
      phx-target={@myself}
      phx-disable-with="Asking Stripe..."
      data-confirm={@confirm}
      data-testid={"bill-#{@action}"}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp draft(customer_id, params, tenant) do
    %{
      provider: "stripe",
      tenant: tenant,
      customer_id: customer_id,
      items: [
        %{
          name: blank_nil(params["item_name"]),
          amount: %{amount: blank_nil(params["item_amount"]), currency: "USD"},
          quantity: integer(params["item_quantity"]) || 1
        }
      ],
      collection: blank_nil(params["collection"]),
      days_until_due: integer(params["days_until_due"]),
      description: blank_nil(params["description"]),
      reference: "bill-" <> Ecto.UUID.generate()
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp call("finalize", id, tenant), do: MishkaPay.finalize_invoice("stripe", id, tenant)
  defp call("send", id, tenant), do: MishkaPay.send_invoice("stripe", id, tenant)

  defp call("pay_out_of_band", id, tenant),
    do: MishkaPay.pay_invoice("stripe", id, tenant, out_of_band: true)

  defp call("void", id, tenant), do: MishkaPay.void_invoice("stripe", id, tenant)

  defp call("uncollectible", id, tenant),
    do: MishkaPay.mark_invoice_uncollectible("stripe", id, tenant)

  defp call("delete", id, tenant), do: MishkaPay.delete_invoice("stripe", id, tenant)
  defp call("read", id, tenant), do: MishkaPay.fetch_invoice("stripe", id, tenant)
  defp call(_unknown, _id, _tenant), do: {:error, "Choose a step from the buttons."}

  defp done("finalize"), do: "Finalized"
  defp done("send"), do: "Emailed"
  defp done("pay_out_of_band"), do: "Paid by other means"
  defp done("void"), do: "Voided"
  defp done("uncollectible"), do: "Marked uncollectible"
  defp done("read"), do: "Read again"

  defp step(socket, label, bill),
    do: update(socket, :steps, &[%{label: label, status: bill.status} | &1])

  # The id typed wins over the one picked.
  defp customer_id(params) do
    case blank_nil(params["customer_id"]) || blank_nil(params["customer"]) do
      nil -> {:error, "Pick a customer, or type its id (cus_...)."}
      id -> {:ok, id}
    end
  end

  defp customers do
    Shop.Pay.Customer
    |> Ash.Query.filter(is_nil(deleted_at))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(30)
    |> Ash.read!(authorize?: false)
  end

  defp money(nil), do: "–"
  defp money(money), do: Money.to_string!(money)

  defp integer(value) do
    case Integer.parse(String.trim(value || "")) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp blank_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_nil(_none), do: nil

  # A refusal shows beside the form that made it, and in the page's alerts.
  defp refused(socket, error) do
    message = if is_binary(error), do: error, else: MishkaPay.Ash.message(error)
    socket |> assign(error: message) |> say(:error, message)
  end

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end
end

defmodule ShopWeb.TaxComponent do
  @moduledoc """
  Tax, read live from Stripe: a business buyer's tax ids (`MishkaPay.create_tax_id/4`,
  `list_tax_ids/4`, `delete_tax_id/4`) with the register check Stripe ran on each, and the tax on
  a sale made outside a checkout (`MishkaPay.calculate_tax/1`: one line, the buyer's country and
  postal code) with its totals, then recorded for the tax reports (`MishkaPay.record_tax/4`).
  Stripe Tax may be off in a sandbox: the page then shows Stripe's refusal in plain words.
  """

  use ShopWeb, :live_component

  require Ash.Query

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @tax_id_form %{"type" => "eu_vat", "value" => "DE123456789"}
  @calc_form %{
    "amount" => "30.00",
    "currency" => "EUR",
    "tax_code" => "txcd_10302000",
    "country" => "DE",
    "postal_code" => ""
  }

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       tax_id_form: @tax_id_form,
       calc_form: @calc_form,
       customer_id: "",
       tax_ids: nil,
       calculation: nil,
       recorded: nil,
       reference: nil,
       customers: nil,
       notice: nil,
       error: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, tenant: assigns.tenant)

    case socket.assigns.customers do
      nil -> {:ok, assign(socket, customers: customer_ids(assigns.tenant))}
      _loaded -> {:ok, socket}
    end
  end

  @impl true
  # Both forms keep what is typed or picked, so a list or a result shown keeps it.
  def handle_event("draft_tax_ids", params, socket), do: {:noreply, keep_tax_id(socket, params)}

  def handle_event("draft_calculation", params, socket),
    do: {:noreply, assign(socket, calc_form: kept(@calc_form, params))}

  # One form, two buttons: list the customer's tax ids, or add one.
  def handle_event(
        "tax_ids",
        %{"intent" => "list", "customer_id" => customer_id} = params,
        socket
      ) do
    {:noreply,
     socket
     |> keep_tax_id(params)
     |> assign(customer_id: String.trim(customer_id), notice: nil, error: nil)
     |> list_tax_ids()}
  end

  def handle_event("tax_ids", %{"customer_id" => customer_id} = params, socket) do
    socket = keep_tax_id(socket, params)
    customer_id = String.trim(customer_id)
    attrs = %{type: params["type"], value: params["value"]}

    case MishkaPay.create_tax_id("stripe", customer_id, attrs, socket.assigns.tenant) do
      {:ok, tax_id} ->
        {:noreply,
         socket
         |> assign(customer_id: customer_id)
         |> list_tax_ids()
         |> done("Tax id #{tax_id.value} added: #{verification(tax_id.verification)}.")}

      {:error, error} ->
        {:noreply, socket |> assign(customer_id: customer_id) |> failed(error)}
    end
  end

  def handle_event("delete_tax_id", %{"id" => id}, socket) do
    %{customer_id: customer_id, tenant: tenant} = socket.assigns

    case MishkaPay.delete_tax_id("stripe", customer_id, id, tenant) do
      :ok ->
        {:noreply, socket |> list_tax_ids() |> done("Tax id removed. Past bills keep it.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  def handle_event("calculate", params, socket) do
    socket = assign(socket, calc_form: kept(@calc_form, params))

    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      items: [
        %{
          reference: "demo-line-1",
          amount: %{amount: params["amount"], currency: params["currency"]},
          tax_code: blank(params["tax_code"])
        }
      ],
      address: %{country: params["country"], postal_code: blank(params["postal_code"])}
    }

    case MishkaPay.calculate_tax(attrs) do
      {:ok, calculation} ->
        {:noreply,
         socket
         |> assign(calculation: calculation, recorded: nil)
         |> assign(reference: "order-#{System.unique_integer([:positive])}")
         |> done("Tax counted by Stripe.")}

      {:error, error} ->
        {:noreply, socket |> assign(calculation: nil, recorded: nil) |> failed(error)}
    end
  end

  def handle_event("record", %{"reference" => reference}, socket) do
    %{calculation: calculation, tenant: tenant} = socket.assigns

    case MishkaPay.record_tax("stripe", calculation.id, reference, tenant) do
      {:ok, transaction} ->
        {:noreply,
         socket
         |> assign(recorded: transaction)
         |> done("Sale recorded for the tax reports: #{transaction.id}.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  defp kept(defaults, params), do: Map.merge(defaults, Map.take(params, Map.keys(defaults)))

  defp keep_tax_id(socket, params) do
    assign(socket,
      customer_id: params["customer_id"] || socket.assigns.customer_id,
      tax_id_form: kept(@tax_id_form, params)
    )
  end

  defp list_tax_ids(%{assigns: %{customer_id: ""}} = socket),
    do: assign(socket, tax_ids: nil, error: "Give a customer id (cus_...).")

  defp list_tax_ids(socket) do
    %{customer_id: customer_id, tenant: tenant} = socket.assigns

    case MishkaPay.list_tax_ids("stripe", customer_id, tenant, limit: 20) do
      {:ok, %MishkaPay.Page{items: tax_ids}} -> assign(socket, tax_ids: tax_ids)
      {:error, error} -> socket |> assign(tax_ids: nil) |> failed(error)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="tax" class="space-y-4">
      <.section_title icon="hero-receipt-percent" title="Tax" />
      <p class="text-sm opacity-70">
        A business buyer's tax ids, checked by Stripe, and the tax on a sale made outside a
        checkout. If Stripe Tax is off in the sandbox, Stripe says so here.
      </p>

      <div :if={@notice} role="status" class="alert alert-success py-2" data-testid="tax-notice">
        {@notice}
      </div>
      <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="tax-error">
        {@error}
      </div>

      <div class="grid gap-4 lg:grid-cols-2">
        <div class="card bg-base-200" data-testid="tax-ids">
          <div class="card-body gap-3">
            <h3 class="font-medium">A customer's tax ids</h3>
            <.hint>MishkaPay.create_tax_id/4, list_tax_ids/4, delete_tax_id/4</.hint>
            <form
              id="tax-ids-form"
              phx-change="draft_tax_ids"
              phx-submit="tax_ids"
              phx-target={@myself}
              class="grid gap-2 sm:grid-cols-2"
              data-testid="tax-ids-form"
            >
              <label class="fieldset sm:col-span-2">
                <span class="fieldset-legend">Customer id</span>
                <input
                  name="customer_id"
                  value={@customer_id}
                  placeholder="cus_..."
                  list="tax-customer-ids"
                  class="input input-sm"
                  data-testid="tax-customer"
                />
                <datalist id="tax-customer-ids">
                  <option :for={id <- @customers} value={id} />
                </datalist>
              </label>
              <label class="fieldset">
                <span class="fieldset-legend">Type</span>
                <select name="type" class="select select-sm" data-testid="tax-id-type">
                  <option
                    :for={
                      {value, label} <- [
                        {"eu_vat", "EU VAT"},
                        {"gb_vat", "UK VAT"},
                        {"au_abn", "Australian ABN"}
                      ]
                    }
                    value={value}
                    selected={@tax_id_form["type"] == value}
                  >
                    {label}
                  </option>
                </select>
              </label>
              <label class="fieldset">
                <span class="fieldset-legend">Number (test: DE123456789)</span>
                <input
                  name="value"
                  value={@tax_id_form["value"]}
                  class="input input-sm"
                  data-testid="tax-id-value"
                />
              </label>
              <div class="flex gap-2 sm:col-span-2">
                <button
                  name="intent"
                  value="add"
                  class="btn btn-sm btn-primary"
                  phx-disable-with="Asking Stripe..."
                  data-testid="tax-id-add"
                >
                  Add tax id
                </button>
                <button name="intent" value="list" class="btn btn-sm" data-testid="tax-ids-list">
                  List
                </button>
              </div>
            </form>

            <ul :if={@tax_ids} class="space-y-1" data-testid="tax-id-rows">
              <li :if={@tax_ids == []} class="text-sm opacity-70" data-testid="tax-ids-empty">
                This customer has no tax ids.
              </li>
              <li
                :for={tax_id <- @tax_ids}
                class="flex flex-wrap items-center gap-2 text-sm"
                data-testid="tax-id-row"
                data-tax-id={tax_id.id}
              >
                <code>{tax_id.type}</code>
                <span class="font-mono">{tax_id.value}</span>
                <span
                  class={["badge badge-sm", badge(tax_id.verification)]}
                  data-testid="tax-id-verification"
                >
                  {verification(tax_id.verification)}
                </span>
                <span :if={tax_id.verified_name} class="opacity-70">{tax_id.verified_name}</span>
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete_tax_id"
                  phx-value-id={tax_id.id}
                  phx-target={@myself}
                  data-confirm="Remove this tax id?"
                  data-testid="tax-id-delete"
                >
                  Remove
                </button>
              </li>
            </ul>
          </div>
        </div>

        <div class="card bg-base-200" data-testid="tax-calculation">
          <div class="card-body gap-3">
            <h3 class="font-medium">Tax on a sale</h3>
            <.hint>MishkaPay.calculate_tax/1, record_tax/4</.hint>
            <form
              id="tax-calc-form"
              phx-change="draft_calculation"
              phx-submit="calculate"
              phx-target={@myself}
              class="grid gap-2 sm:grid-cols-3"
              data-testid="tax-calc-form"
            >
              <label class="fieldset">
                <span class="fieldset-legend">Amount</span>
                <input
                  name="amount"
                  value={@calc_form["amount"]}
                  type="number"
                  step="0.01"
                  min="0.01"
                  class="input input-sm"
                  data-testid="tax-calc-amount"
                />
              </label>
              <label class="fieldset">
                <span class="fieldset-legend">Currency</span>
                <select name="currency" class="select select-sm" data-testid="tax-calc-currency">
                  <option
                    :for={currency <- ~w(EUR USD GBP)}
                    value={currency}
                    selected={@calc_form["currency"] == currency}
                  >
                    {currency}
                  </option>
                </select>
              </label>
              <label class="fieldset">
                <span class="fieldset-legend">Tax code</span>
                <input
                  name="tax_code"
                  value={@calc_form["tax_code"]}
                  class="input input-sm"
                  data-testid="tax-calc-code"
                />
              </label>
              <label class="fieldset">
                <span class="fieldset-legend">Buyer's country</span>
                <select name="country" class="select select-sm" data-testid="tax-calc-country">
                  <option
                    :for={
                      {code, name} <- [
                        {"DE", "Germany"},
                        {"NL", "Netherlands"},
                        {"GB", "United Kingdom"},
                        {"US", "United States"}
                      ]
                    }
                    value={code}
                    selected={@calc_form["country"] == code}
                  >
                    {name}
                  </option>
                </select>
              </label>
              <label class="fieldset">
                <span class="fieldset-legend">Postal code (US needs it)</span>
                <input
                  name="postal_code"
                  value={@calc_form["postal_code"]}
                  placeholder="10115"
                  class="input input-sm"
                  data-testid="tax-calc-postal"
                />
              </label>
              <div class="flex items-end">
                <button
                  class="btn btn-sm btn-primary"
                  phx-disable-with="Asking Stripe..."
                  data-testid="tax-calc-submit"
                >
                  Count the tax
                </button>
              </div>
            </form>

            <div
              :if={@calculation}
              class="rounded-box bg-base-100 p-3 space-y-2"
              data-testid="tax-calc-result"
            >
              <dl class="grid grid-cols-2 gap-y-1 text-sm">
                <dt class="opacity-70">Buyer pays</dt>
                <dd class="font-semibold" data-testid="tax-calc-total">
                  {money(@calculation.amount_total)}
                </dd>
                <dt class="opacity-70">Tax added</dt>
                <dd data-testid="tax-calc-tax">{money(@calculation.tax_amount_exclusive)}</dd>
                <dt class="opacity-70">Tax inside the price</dt>
                <dd data-testid="tax-calc-inclusive">{money(@calculation.tax_amount_inclusive)}</dd>
                <dt class="opacity-70">Calculation</dt>
                <dd class="font-mono text-xs" data-testid="tax-calc-id">{@calculation.id}</dd>
              </dl>
              <form
                id="tax-record-form"
                phx-submit="record"
                phx-target={@myself}
                class="join"
                data-testid="tax-record-form"
              >
                <input
                  name="reference"
                  value={@reference}
                  class="input input-sm join-item"
                  data-testid="tax-record-reference"
                />
                <button
                  class="btn btn-sm join-item"
                  phx-disable-with="Asking Stripe..."
                  data-testid="tax-record-submit"
                >
                  Record the sale
                </button>
              </form>
              <p :if={@recorded} class="text-sm" data-testid="tax-record-result">
                Recorded as <code>{@recorded.id}</code> for {@recorded.reference}.
              </p>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp customer_ids(tenant) do
    Shop.Pay.Customer
    |> Ash.Query.filter(tenant == ^tenant and is_nil(deleted_at))
    |> Ash.Query.limit(20)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.provider_id)
  end

  defp verification(:verified), do: "verified"
  defp verification(:unverified), do: "not verified"
  defp verification(:pending), do: "being checked"
  defp verification(_unavailable), do: "no check for this kind"

  defp badge(:verified), do: "badge-success"
  defp badge(:unverified), do: "badge-error"
  defp badge(:pending), do: "badge-warning"
  defp badge(_other), do: "badge-ghost"

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

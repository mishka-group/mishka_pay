defmodule ShopWeb.UsageComponent do
  @moduledoc """
  Usage billing, read live from Stripe: make a meter (`MishkaPay.create_meter/1`), list them
  (`list_meters/3`) and turn one off (`deactivate_meter/3`); report what a customer used
  (`report_usage/1`, with a reference so it never counts twice) and read what a meter counted for
  them (`usage_summary/6`); and a price that bills a meter's count each period (`create_price/1`
  with `meter_id` and an interval).
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @windows %{"hour" => 3600, "day" => 86_400, "month" => 30 * 86_400}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       meters: nil,
       reported: nil,
       summary: nil,
       price: nil,
       reference: reference(),
       notice: nil,
       error: nil
     )}
  end

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, tenant: assigns.tenant)}

  @impl true
  def handle_event("create_meter", params, socket) do
    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      name: params["name"],
      event_name: params["event_name"],
      aggregation: params["aggregation"]
    }

    case MishkaPay.create_meter(attrs) do
      {:ok, meter} -> {:noreply, socket |> list_meters() |> done("Meter #{meter.id} made.")}
      {:error, error} -> {:noreply, failed(socket, error)}
    end
  end

  def handle_event("list_meters", _params, socket),
    do: {:noreply, socket |> assign(notice: nil, error: nil) |> list_meters()}

  def handle_event("deactivate", %{"id" => id}, socket) do
    case MishkaPay.deactivate_meter("stripe", id, socket.assigns.tenant) do
      {:ok, meter} ->
        # Stripe's list can lag a moment behind: the row takes the meter Stripe answered.
        {:noreply,
         socket
         |> update(:meters, fn meters ->
           Enum.map(meters || [], &if(&1.id == meter.id, do: meter, else: &1))
         end)
         |> done("Meter #{meter.id} is off: it takes no more usage.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  def handle_event("report", params, socket) do
    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      event_name: params["event_name"],
      customer_id: params["customer_id"],
      value: params["value"],
      reference: params["reference"]
    }

    case MishkaPay.report_usage(attrs) do
      {:ok, usage} ->
        {:noreply,
         socket
         |> assign(reported: usage, reference: reference())
         |> done("Usage reported. Stripe counts it within a few minutes.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  def handle_event("summary", params, socket) do
    to = DateTime.utc_now()
    from = DateTime.add(to, -Map.get(@windows, params["window"], 3600), :second)
    %{tenant: tenant} = socket.assigns

    case MishkaPay.usage_summary(
           "stripe",
           params["meter_id"],
           params["customer_id"],
           from,
           to,
           tenant
         ) do
      {:ok, summary} ->
        {:noreply, socket |> assign(summary: summary) |> done("Usage read from Stripe.")}

      {:error, error} ->
        {:noreply, socket |> assign(summary: nil) |> failed(error)}
    end
  end

  def handle_event("metered_price", params, socket) do
    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      product_id: params["product_id"],
      meter_id: params["meter_id"],
      amount: %{amount: params["amount"], currency: params["currency"]},
      interval: params["interval"]
    }

    case MishkaPay.create_price(attrs) do
      {:ok, price} ->
        {:noreply, socket |> assign(price: price) |> done("Metered price #{price.id} made.")}

      {:error, error} ->
        {:noreply, socket |> assign(price: nil) |> failed(error)}
    end
  end

  defp list_meters(socket) do
    case MishkaPay.list_meters("stripe", socket.assigns.tenant, limit: 20) do
      {:ok, %MishkaPay.Page{items: meters}} -> assign(socket, meters: meters)
      {:error, error} -> failed(socket, error)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="usage" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <.section_title icon="hero-chart-bar" title="Usage billing" />
        <button
          class="btn btn-sm"
          phx-click="list_meters"
          phx-target={@myself}
          phx-disable-with="Asking Stripe..."
          data-testid="meters-list"
        >
          <.icon name="hero-arrow-path" class="size-4" /> List meters
        </button>
      </div>
      <p class="text-sm opacity-70">
        A meter counts what customers use; a price on it bills that count each period.
      </p>
      <.hint>
        MishkaPay.create_meter/1, list_meters/3, report_usage/1, usage_summary/6, deactivate_meter/3
      </.hint>

      <div :if={@notice} role="status" class="alert alert-success py-2" data-testid="usage-notice">
        {@notice}
      </div>
      <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="usage-error">
        {@error}
      </div>

      <form
        id="meter-form"
        phx-submit="create_meter"
        phx-target={@myself}
        class="card bg-base-200"
        data-testid="meter-form"
      >
        <div class="card-body gap-3">
          <h3 class="font-medium">New meter</h3>
          <div class="grid gap-3 sm:grid-cols-3">
            <label class="fieldset">
              <span class="fieldset-legend">Name</span>
              <input
                name="name"
                placeholder="API calls"
                class="input input-sm"
                data-testid="meter-name"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Event name</span>
              <input
                name="event_name"
                placeholder="api_call"
                class="input input-sm"
                data-testid="meter-event"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Adds up as</span>
              <select name="aggregation" class="select select-sm" data-testid="meter-aggregation">
                <option value="sum">Sum of values</option>
                <option value="count">Count of reports</option>
                <option value="last">Last value</option>
              </select>
            </label>
          </div>
          <div>
            <button
              class="btn btn-sm btn-primary"
              phx-disable-with="Asking Stripe..."
              data-testid="meter-submit"
            >
              Make meter
            </button>
          </div>
        </div>
      </form>

      <div :if={@meters} class="overflow-x-auto rounded-box border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>Meter</th>
              <th>Event name</th>
              <th>Adds up as</th>
              <th>State</th>
              <th></th>
            </tr>
          </thead>
          <tbody data-testid="meter-rows">
            <tr :if={@meters == []}>
              <td colspan="5" class="text-center opacity-70" data-testid="meters-empty">
                No meters yet.
              </td>
            </tr>
            <tr :for={meter <- @meters} data-testid="meter-row" data-meter-id={meter.id}>
              <td>
                <div class="font-medium">{meter.name}</div>
                <div class="text-xs opacity-60 font-mono">{meter.id}</div>
              </td>
              <td class="font-mono text-xs">{meter.event_name}</td>
              <td>{meter.aggregation}</td>
              <td>
                <span
                  class={[
                    "badge badge-sm",
                    (meter.status == :active && "badge-success") || "badge-ghost"
                  ]}
                  data-testid="meter-status"
                >
                  {meter.status}
                </span>
              </td>
              <td>
                <button
                  :if={meter.status == :active}
                  class="btn btn-xs btn-error btn-outline"
                  phx-click="deactivate"
                  phx-value-id={meter.id}
                  phx-target={@myself}
                  data-confirm="Turn this meter off? It takes no more usage."
                  data-testid="meter-deactivate"
                >
                  Turn off
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="grid gap-4 lg:grid-cols-3">
        <form
          id="usage-report-form"
          phx-submit="report"
          phx-target={@myself}
          class="card bg-base-200"
          data-testid="usage-report-form"
        >
          <div class="card-body gap-2">
            <h3 class="font-medium">Report usage</h3>
            <.meter_events meters={@meters} />
            <.input_field
              name="customer_id"
              label="Customer id"
              placeholder="cus_..."
              testid="usage-customer"
            />
            <.input_field name="value" label="How much" value="1" testid="usage-value" />
            <.input_field
              name="reference"
              label="Reference (counts once)"
              value={@reference}
              testid="usage-reference"
            />
            <div>
              <button
                class="btn btn-sm btn-primary"
                phx-disable-with="Asking Stripe..."
                data-testid="usage-report"
              >
                Report
              </button>
            </div>
            <p :if={@reported} class="text-sm" data-testid="usage-reported">
              Reported {to_string(@reported.value)} for {@reported.customer_id} as <code>{@reported.id}</code>.
            </p>
          </div>
        </form>

        <form
          id="usage-summary-form"
          phx-submit="summary"
          phx-target={@myself}
          class="card bg-base-200"
          data-testid="usage-summary-form"
        >
          <div class="card-body gap-2">
            <h3 class="font-medium">What a meter counted</h3>
            <.meter_ids meters={@meters} testid="summary-meter" />
            <.input_field
              name="customer_id"
              label="Customer id"
              placeholder="cus_..."
              testid="summary-customer"
            />
            <label class="fieldset">
              <span class="fieldset-legend">Since</span>
              <select name="window" class="select select-sm" data-testid="summary-window">
                <option value="hour">One hour ago</option>
                <option value="day">One day ago</option>
                <option value="month">30 days ago</option>
              </select>
            </label>
            <div>
              <button
                class="btn btn-sm"
                phx-disable-with="Asking Stripe..."
                data-testid="summary-submit"
              >
                Read
              </button>
            </div>
            <p :if={@summary} class="text-sm" data-testid="usage-summary">
              <span class="text-lg font-semibold" data-testid="usage-summary-value">{to_string(
                @summary.value
              )}</span>
              counted for {@summary.customer_id}
            </p>
          </div>
        </form>

        <form
          id="metered-price-form"
          phx-submit="metered_price"
          phx-target={@myself}
          class="card bg-base-200"
          data-testid="metered-price-form"
        >
          <div class="card-body gap-2">
            <h3 class="font-medium">Metered price</h3>
            <.input_field
              name="product_id"
              label="Product id"
              placeholder="prod_..."
              testid="metered-product"
            />
            <.meter_ids meters={@meters} testid="metered-meter" />
            <.input_field name="amount" label="Per unit" value="0.05" testid="metered-amount" />
            <div class="grid grid-cols-2 gap-2">
              <label class="fieldset">
                <span class="fieldset-legend">Currency</span>
                <select name="currency" class="select select-sm" data-testid="metered-currency">
                  <option value="USD">USD</option>
                  <option value="EUR">EUR</option>
                </select>
              </label>
              <label class="fieldset">
                <span class="fieldset-legend">Billed every</span>
                <select name="interval" class="select select-sm" data-testid="metered-interval">
                  <option value="month">month</option>
                  <option value="year">year</option>
                </select>
              </label>
            </div>
            <div>
              <button
                class="btn btn-sm"
                phx-disable-with="Asking Stripe..."
                data-testid="metered-submit"
              >
                Make price
              </button>
            </div>
            <p :if={@price} class="text-sm" data-testid="metered-price">
              <code>{@price.id}</code> bills {@price.meter_id} every {@price.interval}.
            </p>
          </div>
        </form>
      </div>
    </section>
    """
  end

  attr :meters, :list, default: nil

  defp meter_events(assigns) do
    ~H"""
    <label class="fieldset">
      <span class="fieldset-legend">Meter's event name</span>
      <input
        name="event_name"
        list="usage-event-names"
        placeholder="api_call"
        class="input input-sm"
        data-testid="usage-event"
      />
      <datalist id="usage-event-names">
        <option :for={meter <- @meters || []} value={meter.event_name} />
      </datalist>
    </label>
    """
  end

  attr :meters, :list, default: nil
  attr :testid, :string, required: true

  defp meter_ids(assigns) do
    ~H"""
    <label class="fieldset">
      <span class="fieldset-legend">Meter id</span>
      <input
        name="meter_id"
        list={"#{@testid}-ids"}
        placeholder="mtr_..."
        class="input input-sm"
        data-testid={@testid}
      />
      <datalist id={"#{@testid}-ids"}>
        <option :for={meter <- @meters || []} value={meter.id} />
      </datalist>
    </label>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :testid, :string, required: true
  attr :value, :string, default: nil
  attr :placeholder, :string, default: nil

  defp input_field(assigns) do
    ~H"""
    <label class="fieldset">
      <span class="fieldset-legend">{@label}</span>
      <input
        name={@name}
        value={@value}
        placeholder={@placeholder}
        class="input input-sm"
        data-testid={@testid}
      />
    </label>
    """
  end

  defp reference, do: "use-#{System.unique_integer([:positive])}"

  defp done(socket, message), do: assign(socket, notice: message, error: nil)

  defp failed(socket, error), do: assign(socket, error: MishkaPay.Ash.message(error), notice: nil)
end

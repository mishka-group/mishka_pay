defmodule ShopWeb.UsageComponent do
  @moduledoc """
  Usage billing, read live from Stripe: make a meter (`MishkaPay.create_meter/1`), list them
  (`list_meters/3`), turn one off (`deactivate_meter/3`) and on again (`reactivate_meter/3`);
  report what a customer used (`report_usage/1`, with a reference so it never counts twice), take
  a report sent by mistake back (`cancel_usage/1`) and read what a meter counted for them
  (`usage_summary/6`); and a price that bills a meter's count each period (`create_price/1` with
  `meter_id` and an interval).
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @windows %{"hour" => 3600, "day" => 86_400, "month" => 30 * 86_400}

  # What the forms keep between re-renders: the selects of the meter, summary and price forms
  # (their other fields are function components LiveView leaves alone while their attributes do
  # not change), and all the report form's fields, so a refused report keeps what was typed.
  @meter_form %{"name" => "", "event_name" => "", "aggregation" => "sum"}
  @summary_form %{"window" => "hour"}
  @price_form %{"currency" => "USD", "interval" => "month"}
  @report_form %{"event_name" => "", "customer_id" => "", "value" => "1", "reference" => ""}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       meter_form: @meter_form,
       summary_form: @summary_form,
       price_form: @price_form,
       report_form: %{@report_form | "reference" => reference()},
       report_error: nil,
       meters: nil,
       reported: nil,
       cancelled: nil,
       summary: nil,
       price: nil,
       notice: nil,
       error: nil
     )}
  end

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, tenant: assigns.tenant)}

  @impl true
  def handle_event("draft_report", params, socket),
    do: {:noreply, socket |> keep("report", params) |> assign(report_error: nil)}

  def handle_event("draft_" <> form, params, socket), do: {:noreply, keep(socket, form, params)}

  def handle_event("create_meter", params, socket) do
    socket = keep(socket, "meter", params)

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
        {:noreply,
         socket
         |> put_meter(meter)
         |> done("Meter #{meter.id} is off: it takes no more usage.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  def handle_event("reactivate", %{"id" => id}, socket) do
    case MishkaPay.reactivate_meter("stripe", id, socket.assigns.tenant) do
      {:ok, meter} ->
        {:noreply,
         socket
         |> put_meter(meter)
         |> done("Meter #{meter.id} is on again: it takes usage.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  def handle_event("cancel_usage", _params, %{assigns: %{reported: %MishkaPay.Usage{}}} = socket) do
    %{reported: usage, tenant: tenant} = socket.assigns

    attrs = %{
      provider: "stripe",
      tenant: tenant,
      event_name: usage.event_name,
      usage_id: usage.id
    }

    case MishkaPay.cancel_usage(attrs) do
      {:ok, cancel} ->
        {:noreply,
         socket
         |> assign(cancelled: cancel)
         |> done("Report #{cancel.usage_id} taken back (#{cancel.status}): it no longer counts.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  def handle_event("report", params, socket) do
    socket = keep(socket, "report", params)

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
         |> assign(reported: usage, cancelled: nil, report_error: nil)
         |> update(:report_form, &%{&1 | "reference" => reference()})
         |> done("Usage reported. Stripe counts it within a few minutes.")}

      {:error, error} ->
        {:noreply, assign(socket, report_error: MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("summary", params, socket) do
    socket = keep(socket, "summary", params)
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
    socket = keep(socket, "price", params)

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

  defp keep(socket, "meter", params), do: assign(socket, meter_form: kept(@meter_form, params))

  defp keep(socket, "summary", params),
    do: assign(socket, summary_form: kept(@summary_form, params))

  defp keep(socket, "price", params), do: assign(socket, price_form: kept(@price_form, params))

  defp keep(socket, "report", params),
    do: assign(socket, report_form: kept(@report_form, params))

  defp kept(defaults, params), do: Map.merge(defaults, Map.take(params, Map.keys(defaults)))

  # Stripe's list can lag a moment behind: the row takes the meter Stripe answered.
  defp put_meter(socket, meter) do
    update(socket, :meters, fn meters ->
      Enum.map(meters || [], &if(&1.id == meter.id, do: meter, else: &1))
    end)
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
        MishkaPay.create_meter/1, list_meters/3, report_usage/1, cancel_usage/1, usage_summary/6, deactivate_meter/3, reactivate_meter/3
      </.hint>

      <div :if={@notice} role="status" class="alert alert-success py-2" data-testid="usage-notice">
        {@notice}
      </div>
      <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="usage-error">
        {@error}
      </div>

      <form
        id="meter-form"
        phx-change="draft_meter"
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
                value={@meter_form["name"]}
                placeholder="API calls"
                class="input input-sm"
                data-testid="meter-name"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Event name</span>
              <input
                name="event_name"
                value={@meter_form["event_name"]}
                placeholder="api_call"
                class="input input-sm"
                data-testid="meter-event"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Adds up as</span>
              <select name="aggregation" class="select select-sm" data-testid="meter-aggregation">
                <option
                  :for={
                    {value, label} <- [
                      {"sum", "Sum of values"},
                      {"count", "Count of reports"},
                      {"last", "Last value"}
                    ]
                  }
                  value={value}
                  selected={@meter_form["aggregation"] == value}
                >
                  {label}
                </option>
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
                <button
                  :if={meter.status == :inactive}
                  class="btn btn-xs btn-outline"
                  phx-click="reactivate"
                  phx-value-id={meter.id}
                  phx-target={@myself}
                  data-testid="meter-reactivate"
                >
                  Turn on
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="grid gap-4 lg:grid-cols-3">
        <form
          id="usage-report-form"
          phx-change="draft_report"
          phx-submit="report"
          phx-target={@myself}
          class="card bg-base-200"
          data-testid="usage-report-form"
        >
          <div class="card-body gap-2">
            <h3 class="font-medium">Report usage</h3>
            <.meter_events meters={@meters} value={@report_form["event_name"]} />
            <.input_field
              name="customer_id"
              label="Customer id"
              value={@report_form["customer_id"]}
              placeholder="cus_..."
              testid="usage-customer"
            />
            <.input_field
              name="value"
              label="How much"
              value={@report_form["value"]}
              testid="usage-value"
            />
            <.input_field
              name="reference"
              label="Reference (counts once)"
              value={@report_form["reference"]}
              testid="usage-reference"
            />
            <p
              :if={@report_error}
              role="alert"
              class="alert alert-error py-2 text-sm"
              data-testid="usage-report-error"
            >
              {@report_error}
            </p>
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
            <div :if={@reported && !@cancelled}>
              <button
                type="button"
                class="btn btn-xs btn-outline btn-warning"
                phx-click="cancel_usage"
                phx-target={@myself}
                phx-disable-with="Asking Stripe..."
                data-confirm="Take this report back? It will not be counted."
                data-testid="usage-cancel"
              >
                Take back this report
              </button>
            </div>
            <p :if={@cancelled} class="text-sm" data-testid="usage-cancelled">
              Taken back: <code>{@cancelled.usage_id}</code>
              <span class="badge badge-sm" data-testid="usage-cancel-status">
                {@cancelled.status}
              </span>
            </p>
          </div>
        </form>

        <form
          id="usage-summary-form"
          phx-change="draft_summary"
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
                <option
                  :for={
                    {value, label} <- [
                      {"hour", "One hour ago"},
                      {"day", "One day ago"},
                      {"month", "30 days ago"}
                    ]
                  }
                  value={value}
                  selected={@summary_form["window"] == value}
                >
                  {label}
                </option>
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
          phx-change="draft_price"
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
                  <option
                    :for={currency <- ~w(USD EUR)}
                    value={currency}
                    selected={@price_form["currency"] == currency}
                  >
                    {currency}
                  </option>
                </select>
              </label>
              <label class="fieldset">
                <span class="fieldset-legend">Billed every</span>
                <select name="interval" class="select select-sm" data-testid="metered-interval">
                  <option
                    :for={interval <- ~w(month year)}
                    value={interval}
                    selected={@price_form["interval"] == interval}
                  >
                    {interval}
                  </option>
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
  attr :value, :string, default: nil

  defp meter_events(assigns) do
    ~H"""
    <label class="fieldset">
      <span class="fieldset-legend">Meter's event name</span>
      <input
        name="event_name"
        list="usage-event-names"
        value={@value}
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

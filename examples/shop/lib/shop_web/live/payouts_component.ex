defmodule ShopWeb.PayoutsComponent do
  @moduledoc """
  Paying the balance out to the bank, read and set live at Stripe: when the balance is paid out
  by itself (`MishkaPay.fetch_payout_schedule/2`, `MishkaPay.update_payout_schedule/1`), the bank
  accounts and cards it goes to with their bank and last four digits
  (`MishkaPay.list_payout_destinations/3`), and a payout made now
  (`MishkaPay.create_payout/1`), once per press.

  Nothing is read until a button is pressed. Stripe's refusal (a test key reading the platform's
  own banks, a balance without the money) shows inside the part's own card.
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @weekdays ~w(monday tuesday wednesday thursday friday)

  @schedule_form %{
    "interval" => "daily",
    "weekly_days" => [],
    "monthly_days" => "",
    "delay_days" => ""
  }

  @payout_form %{"amount" => "1.00", "currency" => "USD", "method" => "standard"}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       schedule: nil,
       schedule_form: @schedule_form,
       destinations: nil,
       payout_form: @payout_form,
       payout: nil,
       notice: nil,
       error: nil
     )}
  end

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, tenant: assigns.tenant)}

  @impl true
  def handle_event("read_schedule", _params, socket) do
    case MishkaPay.fetch_payout_schedule("stripe", socket.assigns.tenant) do
      {:ok, schedule} ->
        {:noreply,
         assign(socket, schedule: schedule, schedule_form: form_of(schedule), error: nil)}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  def handle_event("draft_schedule", params, socket),
    do: {:noreply, assign(socket, schedule_form: Map.merge(@schedule_form, params))}

  def handle_event("save_schedule", params, socket) do
    params = Map.merge(@schedule_form, params)

    attrs =
      %{
        provider: "stripe",
        tenant: socket.assigns.tenant,
        interval: params["interval"],
        weekly_days:
          if(params["interval"] == "weekly",
            do: Enum.reject(List.wrap(params["weekly_days"]), &(&1 == ""))
          ),
        monthly_days: if(params["interval"] == "monthly", do: days(params["monthly_days"])),
        delay_days: delay(params["delay_days"])
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case MishkaPay.update_payout_schedule(attrs) do
      {:ok, schedule} ->
        {:noreply,
         assign(socket,
           schedule: schedule,
           schedule_form: form_of(schedule),
           notice: "Payout schedule saved at Stripe.",
           error: nil
         )}

      {:error, error} ->
        {:noreply, socket |> assign(schedule_form: params) |> failed(error)}
    end
  end

  def handle_event("read_destinations", _params, socket) do
    case MishkaPay.list_payout_destinations("stripe", socket.assigns.tenant, limit: 10) do
      {:ok, %{items: items}} -> {:noreply, assign(socket, destinations: items, error: nil)}
      {:error, error} -> {:noreply, socket |> assign(destinations: nil) |> failed(error)}
    end
  end

  def handle_event("draft_payout", params, socket),
    do: {:noreply, assign(socket, payout_form: params)}

  def handle_event("pay_out", params, socket) do
    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      amount: %{amount: String.trim(params["amount"] || ""), currency: params["currency"]},
      method: params["method"],
      reference: "payout-#{System.unique_integer([:positive])}"
    }

    case MishkaPay.create_payout(attrs) do
      {:ok, payout} ->
        {:noreply,
         assign(socket,
           payout_form: params,
           payout: payout,
           notice: "Payout #{payout.id} made: #{payout.status}.",
           error: nil
         )}

      {:error, error} ->
        {:noreply, socket |> assign(payout_form: params, payout: nil) |> failed(error)}
    end
  end

  defp failed(socket, error), do: assign(socket, notice: nil, error: MishkaPay.Ash.message(error))

  defp form_of(schedule) do
    %{
      "interval" => to_string(schedule.interval || "daily"),
      "weekly_days" => Enum.map(schedule.weekly_days || [], &to_string/1),
      "monthly_days" => Enum.join(schedule.monthly_days || [], ", "),
      "delay_days" => to_string(schedule.delay_days || "")
    }
  end

  defp days(text) do
    text
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn day ->
      case Integer.parse(day) do
        {number, ""} -> [number]
        _not_a_day -> [day]
      end
    end)
  end

  defp delay(text) do
    case String.trim(to_string(text)) do
      "" -> nil
      "default" -> :default
      days -> String.to_integer(days)
    end
  rescue
    ArgumentError -> -1
  end

  defp money(nil), do: "-"
  defp money(money), do: Money.to_string!(money)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, weekdays: @weekdays)

    ~H"""
    <section data-testid="payouts" class="space-y-4">
      <.section_title icon="hero-building-library" title="Payouts" />
      <p class="text-sm opacity-70">
        When Stripe pays the balance out to the bank by itself, which bank it goes to, and a
        payout made now. A test key reads the platform's own banks only with live keys: Stripe's
        refusal shows here.
      </p>
      <.hint>
        MishkaPay.fetch_payout_schedule/2, update_payout_schedule/1, list_payout_destinations/3,
        fetch_payout_destination/3, create_payout/1
      </.hint>

      <div :if={@notice} role="status" class="alert alert-success py-2" data-testid="payouts-notice">
        {@notice}
      </div>
      <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="payouts-error">
        {@error}
      </div>

      <div class="card bg-base-200" data-testid="payout-schedule">
        <div class="card-body gap-3">
          <div class="flex items-center gap-2">
            <h3 class="font-semibold">Schedule</h3>
            <button
              class="btn btn-sm"
              phx-click="read_schedule"
              phx-target={@myself}
              data-testid="payout-schedule-read"
            >
              Read schedule
            </button>
          </div>

          <dl :if={@schedule} class="grid grid-cols-2 gap-1 text-sm sm:grid-cols-4">
            <dt>Interval</dt>
            <dd data-testid="payout-schedule-interval">{@schedule.interval}</dd>
            <dt>Days</dt>
            <dd data-testid="payout-schedule-days">
              {Enum.join(@schedule.weekly_days || @schedule.monthly_days || [], ", ")}
            </dd>
            <dt>Delay days</dt>
            <dd data-testid="payout-schedule-delay">{@schedule.delay_days}</dd>
            <dt>Status</dt>
            <dd data-testid="payout-schedule-status">{@schedule.status}</dd>
            <dt>Kept back</dt>
            <dd data-testid="payout-schedule-minimum-balances">
              {Enum.map_join(@schedule.minimum_balances || [], ", ", &money/1)}
            </dd>
            <dt>Smallest payout</dt>
            <dd data-testid="payout-schedule-minimum-payouts">
              {if @schedule.minimum_payouts == [],
                do: "Stripe's API does not say",
                else: Enum.map_join(@schedule.minimum_payouts, ", ", &money/1)}
            </dd>
          </dl>

          <form
            id="payout-schedule-form"
            phx-change="draft_schedule"
            phx-submit="save_schedule"
            phx-target={@myself}
            class="grid gap-3 sm:grid-cols-4"
            data-testid="payout-schedule-form"
          >
            <label class="fieldset">
              <span class="fieldset-legend">Interval</span>
              <select
                name="interval"
                class="select select-sm"
                data-testid="payout-schedule-interval-input"
              >
                <option
                  :for={value <- ~w(manual daily weekly monthly)}
                  value={value}
                  selected={@schedule_form["interval"] == value}
                >
                  {value}
                </option>
              </select>
            </label>
            <fieldset
              :if={@schedule_form["interval"] == "weekly"}
              class="fieldset"
              data-testid="payout-schedule-weekdays"
            >
              <span class="fieldset-legend">Days of the week</span>
              <input type="hidden" name="weekly_days[]" value="" />
              <label :for={day <- @weekdays} class="label text-xs">
                <input
                  type="checkbox"
                  name="weekly_days[]"
                  value={day}
                  checked={day in (@schedule_form["weekly_days"] || [])}
                  class="checkbox checkbox-xs"
                  data-testid={"payout-schedule-weekday-#{day}"}
                />
                {day}
              </label>
            </fieldset>
            <label :if={@schedule_form["interval"] == "monthly"} class="fieldset">
              <span class="fieldset-legend">Days of the month</span>
              <input
                name="monthly_days"
                value={@schedule_form["monthly_days"]}
                placeholder="1, 15"
                class="input input-sm"
                data-testid="payout-schedule-monthdays"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Delay days (or "default")</span>
              <input
                name="delay_days"
                value={@schedule_form["delay_days"]}
                placeholder="as it is"
                class="input input-sm"
                data-testid="payout-schedule-delay-input"
              />
            </label>
            <div class="flex items-end">
              <button class="btn btn-sm btn-primary" data-testid="payout-schedule-save">
                Save schedule
              </button>
            </div>
          </form>
        </div>
      </div>

      <div class="card bg-base-200" data-testid="payout-destinations">
        <div class="card-body gap-3">
          <div class="flex items-center gap-2">
            <h3 class="font-semibold">Bank accounts and cards</h3>
            <button
              class="btn btn-sm"
              phx-click="read_destinations"
              phx-target={@myself}
              data-testid="payout-destinations-read"
            >
              Read banks
            </button>
          </div>
          <table :if={@destinations} class="table table-sm">
            <thead>
              <tr>
                <th>Id</th>
                <th>Bank or card</th>
                <th>Last four</th>
                <th>Currency</th>
                <th>Default</th>
              </tr>
            </thead>
            <tbody data-testid="payout-destination-rows">
              <tr :if={@destinations == []}>
                <td colspan="5" class="text-center opacity-70" data-testid="payout-destinations-empty">
                  No bank account or card.
                </td>
              </tr>
              <tr
                :for={destination <- @destinations}
                data-testid="payout-destination-row"
                data-destination-id={destination.id}
              >
                <td class="font-mono text-xs">{destination.id}</td>
                <td data-testid="payout-destination-bank">
                  {destination.bank_name || destination.card_brand}
                </td>
                <td data-testid="payout-destination-last4">{destination.last4}</td>
                <td>{destination.currency}</td>
                <td data-testid="payout-destination-default">{destination.default}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <form
        id="payout-form"
        phx-change="draft_payout"
        phx-submit="pay_out"
        phx-target={@myself}
        class="card bg-base-200"
        data-testid="payout-form"
      >
        <div class="card-body gap-3">
          <h3 class="font-semibold">Pay out now</h3>
          <div class="grid gap-3 sm:grid-cols-4">
            <label class="fieldset">
              <span class="fieldset-legend">Amount</span>
              <input
                name="amount"
                value={@payout_form["amount"]}
                class="input input-sm"
                data-testid="payout-amount"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Currency</span>
              <input
                name="currency"
                value={@payout_form["currency"]}
                class="input input-sm"
                data-testid="payout-currency"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Method</span>
              <select name="method" class="select select-sm" data-testid="payout-method">
                <option
                  :for={value <- ~w(standard instant)}
                  value={value}
                  selected={@payout_form["method"] == value}
                >
                  {value}
                </option>
              </select>
            </label>
            <div class="flex items-end">
              <button class="btn btn-sm btn-primary" data-testid="payout-create">Pay out</button>
            </div>
          </div>
          <p :if={@payout} class="text-sm" data-testid="payout-made">
            {@payout.id}: {money(@payout.amount)}, {@payout.status}, {@payout.method}
          </p>
        </div>
      </form>
    </section>
    """
  end
end

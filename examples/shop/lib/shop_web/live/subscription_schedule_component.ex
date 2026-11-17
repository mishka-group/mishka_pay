defmodule ShopWeb.SubscriptionScheduleComponent do
  @moduledoc """
  A change planned ahead for one Stripe subscription, in the subscriptions part of the demo
  shop: move it to another plan on a date, or stop it after some periods. The first change makes
  a schedule from the subscription (`MishkaPay.create_subscription_schedule/1` with
  `:subscription_id`), then sets its phases (`MishkaPay.update_subscription_schedule/1`: the
  phase running now until the date, then the new plan; or the phase running now for the periods,
  then an end). The schedule shows its phases, the one running now marked, and is released
  (`MishkaPay.release_subscription_schedule/3`: the subscription goes on alone) or canceled
  (`MishkaPay.cancel_subscription_schedule/4`: the subscription ends now).

  Nothing is read until asked: "Show the schedule" reads it in the background.

  The date field reports its value when it is left (`phx-debounce="blur"`), not on each key: a
  browser's date field answers each key with a whole date, and a re-render of that half-typed
  date would mix it with the next keys.
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [hint: 1]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       subscription: nil,
       schedule: nil,
       open?: false,
       reading?: false,
       form: %{"how" => "next_plan", "periods" => "3"}
     )}
  end

  @impl true
  def update(%{subscription: subscription} = assigns, socket) do
    socket =
      case socket.assigns.subscription do
        %{id: id} when id == subscription.id -> socket
        _another -> assign(socket, schedule: nil, open?: false)
      end

    {:ok,
     assign(socket, subscription: subscription, tenant: assigns.tenant, plans: assigns.plans)}
  end

  @impl true
  def handle_event("open", _params, socket), do: {:noreply, assign(socket, open?: true)}

  def handle_event("draft", params, socket), do: {:noreply, assign(socket, form: params)}

  def handle_event("show", _params, socket) do
    %{subscription: subscription, tenant: tenant} = socket.assigns

    {:noreply,
     socket
     |> assign(reading?: true)
     |> start_async(:show, fn ->
       MishkaPay.fetch_subscription_schedule("stripe", subscription.schedule_id, tenant)
     end)}
  end

  def handle_event("plan", params, socket) do
    socket = assign(socket, form: params)

    with {:ok, phases, end_behavior} <- phases_from(params, socket.assigns),
         {:ok, schedule} <- schedule_of(socket.assigns),
         {:ok, schedule} <- planned(schedule, phases, end_behavior, socket.assigns) do
      {:noreply,
       socket
       |> assign(schedule: schedule, open?: false)
       |> say(:info, "Schedule #{schedule.id} set: #{length(schedule.phases)} phases.")}
    else
      {:error, error} -> {:noreply, refused(socket, error)}
    end
  end

  def handle_event("end", %{"how" => how}, %{assigns: %{schedule: %{id: id}}} = socket) do
    tenant = socket.assigns.tenant

    result =
      case how do
        "release" -> MishkaPay.release_subscription_schedule("stripe", id, tenant)
        "cancel" -> MishkaPay.cancel_subscription_schedule("stripe", id, tenant)
      end

    case result do
      {:ok, schedule} ->
        {:noreply,
         socket
         |> assign(schedule: schedule)
         |> say(:info, ended(schedule.status))}

      {:error, error} ->
        {:noreply, refused(socket, error)}
    end
  end

  @impl true
  def handle_async(:show, {:ok, {:ok, schedule}}, socket),
    do: {:noreply, assign(socket, schedule: schedule, reading?: false)}

  def handle_async(:show, {:ok, {:error, error}}, socket),
    do: {:noreply, socket |> assign(reading?: false) |> refused(error)}

  def handle_async(:show, {:exit, reason}, socket),
    do: {:noreply, socket |> assign(reading?: false) |> say(:error, inspect(reason))}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mt-3 border-t border-base-300 pt-3 space-y-2" data-testid="subscription-schedule">
      <div class="flex flex-wrap items-center gap-2">
        <h5 class="text-sm font-medium">Planned changes</h5>
        <button
          :if={!@open?}
          class="btn btn-xs"
          phx-click="open"
          phx-target={@myself}
          data-testid="schedule-open"
        >
          Schedule a change
        </button>
        <button
          :if={@subscription.schedule_id && is_nil(@schedule)}
          class="btn btn-xs btn-ghost"
          phx-click="show"
          phx-target={@myself}
          disabled={@reading?}
          data-testid="schedule-show"
        >
          Show the schedule
        </button>
        <span :if={@reading?} class="loading loading-dots loading-xs"></span>
      </div>

      <form
        :if={@open?}
        id="schedule-form"
        phx-change="draft"
        phx-submit="plan"
        phx-target={@myself}
        class="grid gap-2 sm:grid-cols-3 items-end text-sm"
        data-testid="schedule-form"
      >
        <.hint>
          MishkaPay.create_subscription_schedule/1 (subscription_id:), update_subscription_schedule/1
        </.hint>
        <label class="fieldset">
          <span class="fieldset-legend">What</span>
          <select name="how" class="select select-sm" data-testid="schedule-how">
            <option value="next_plan" selected={@form["how"] == "next_plan"}>
              Another plan from a date
            </option>
            <option value="stop_after" selected={@form["how"] == "stop_after"}>
              Stop after some periods
            </option>
          </select>
        </label>
        <label :if={@form["how"] != "stop_after"} class="fieldset">
          <span class="fieldset-legend">Plan</span>
          <select name="price_id" class="select select-sm" data-testid="schedule-plan">
            <option
              :for={plan <- @plans}
              value={plan.stripe_price_id}
              selected={@form["price_id"] == plan.stripe_price_id}
            >
              {plan.name} (${plan.price} / {plan.interval})
            </option>
          </select>
        </label>
        <label :if={@form["how"] != "stop_after"} class="fieldset">
          <span class="fieldset-legend">From</span>
          <input
            type="date"
            name="date"
            phx-debounce="blur"
            value={@form["date"]}
            class="input input-sm"
            data-testid="schedule-date"
          />
        </label>
        <label :if={@form["how"] == "stop_after"} class="fieldset">
          <span class="fieldset-legend">Periods from this period's start</span>
          <input
            type="number"
            min="1"
            name="periods"
            value={@form["periods"]}
            class="input input-sm"
            data-testid="schedule-periods"
          />
        </label>
        <button
          class="btn btn-sm btn-primary"
          phx-disable-with="Asking Stripe..."
          data-testid="schedule-submit"
        >
          Set the schedule
        </button>
      </form>

      <div :if={@schedule} class="text-xs space-y-1" data-testid="schedule-card">
        <p>
          <code>{@schedule.id}</code>
          <span class="badge badge-xs" data-testid="schedule-status">{@schedule.status}</span>
          after the last phase: <span data-testid="schedule-end">{@schedule.end_behavior}</span>
        </p>
        <ol class="space-y-1">
          <li
            :for={{phase, index} <- Enum.with_index(@schedule.phases)}
            class={["rounded-box p-1", index == @schedule.current_phase && "bg-primary/10"]}
            data-testid="schedule-phase"
            data-current={to_string(index == @schedule.current_phase)}
          >
            {date(phase.start_at)} to {date(phase.end_at)}:
            <span :for={item <- phase.items}>{item.quantity || 1} × <code>{item.id}</code></span>
            <span :if={phase.trial_end_at} class="opacity-70">(trial)</span>
          </li>
        </ol>
        <div :if={@schedule.status in [:active, :not_started]} class="flex gap-2">
          <button
            class="btn btn-xs"
            phx-click="end"
            phx-value-how="release"
            phx-target={@myself}
            phx-disable-with="Asking Stripe..."
            data-confirm="Release the schedule? The subscription goes on as it is now, without the phases to come."
            data-testid="schedule-release"
          >
            Release
          </button>
          <button
            class="btn btn-xs btn-error btn-outline"
            phx-click="end"
            phx-value-how="cancel"
            phx-target={@myself}
            phx-disable-with="Asking Stripe..."
            data-confirm="Cancel the schedule? Its subscription ends now."
            data-testid="schedule-cancel"
          >
            Cancel it and the subscription
          </button>
        </div>
      </div>
    </div>
    """
  end

  # What the form plans after the phase running now, and what happens after the last phase.
  defp phases_from(%{"how" => "stop_after"} = params, _assigns) do
    case integer(params["periods"]) do
      periods when is_integer(periods) and periods > 0 -> {:ok, {:stop, periods}, :cancel}
      _none -> {:error, "Give how many periods it runs, 1 or more."}
    end
  end

  defp phases_from(params, %{plans: plans}) do
    with %{} = plan <- Enum.find(plans, &(&1.stripe_price_id == params["price_id"])),
         {:ok, date} <- Date.from_iso8601(params["date"] || ""),
         {:ok, at} <- DateTime.new(date, ~T[00:00:00]),
         :gt <- DateTime.compare(at, DateTime.utc_now()) do
      {:ok, {:switch, at, %{id: plan.stripe_price_id}}, :release}
    else
      _no_plan_or_date -> {:error, "Pick a plan and a date still to come."}
    end
  end

  # The schedule shown, the one the subscription has, or a new one made from it.
  defp schedule_of(%{schedule: %{status: status} = schedule})
       when status in [:active, :not_started],
       do: {:ok, schedule}

  defp schedule_of(%{subscription: %{schedule_id: id}, tenant: tenant}) when is_binary(id),
    do: MishkaPay.fetch_subscription_schedule("stripe", id, tenant)

  defp schedule_of(%{subscription: subscription, tenant: tenant}) do
    MishkaPay.create_subscription_schedule(%{
      provider: "stripe",
      tenant: tenant,
      subscription_id: subscription.id,
      reference: "shop-schedule-#{subscription.id}"
    })
  end

  # The phase running now stays as it is (its start, its prices, its trial) until the change.
  defp planned(schedule, plan, end_behavior, %{tenant: tenant, subscription: subscription}) do
    now = Enum.at(schedule.phases, schedule.current_phase || 0)
    items = Enum.map(now.items, &%{id: &1.id, quantity: &1.quantity})
    current = %{items: items, start_at: now.start_at, trial_end_at: now.trial_end_at}

    phases =
      case plan do
        {:switch, at, price} ->
          [Map.put(current, :end_at, at), %{items: [Map.put(price, :quantity, quantity(items))]}]

        {:stop, periods} ->
          [Map.merge(current, %{iterations: periods, interval: interval(subscription)})]
      end

    MishkaPay.update_subscription_schedule(%{
      provider: "stripe",
      tenant: tenant,
      id: schedule.id,
      end_behavior: end_behavior,
      phases: phases
    })
  end

  defp quantity([%{quantity: quantity} | _]) when is_integer(quantity), do: quantity
  defp quantity(_items), do: 1

  # The period a stop counts in: the interval of the subscription's plan.
  defp interval(%{items: [%{interval: interval} | _]}) when not is_nil(interval), do: interval
  defp interval(_subscription), do: :month

  defp ended(:released), do: "Released: the subscription goes on alone."
  defp ended(:canceled), do: "Canceled: the subscription ended. Sync it to see it."
  defp ended(status), do: "The schedule is #{status}."

  defp date(nil), do: "–"
  defp date(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d")

  defp integer(value) do
    case Integer.parse(String.trim(value || "")) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp refused(socket, error) when is_binary(error), do: say(socket, :error, error)
  defp refused(socket, error), do: say(socket, :error, MishkaPay.Ash.message(error))

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end
end

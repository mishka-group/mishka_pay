defmodule ShopWeb.TestClocksComponent do
  @moduledoc """
  The test clocks panel: sets up a subscription on its own Stripe test clock in one of four
  situations, and moves the clock forward to see what time does to it (a renewal paid or failing,
  a trial that ends). Moving a clock is done by Stripe on its servers, so the panel asks the clock
  again every moment until it is ready, then reads the subscription again through Mishka Pay
  (`:sync`), which updates the subscriptions table like any other change.
  """

  use ShopWeb, :live_component

  require Ash.Query

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  alias MishkaPay.Providers.Stripe.TestClock
  alias Shop.Pay.{ClockRun, StripeSandbox, Subscription}

  @scenarios [
    renews: %{
      label: "Monthly, card works",
      plan: "pro-monthly",
      buyer: "Clock Renewal",
      expect: "Move a month: a new invoice is paid and the period moves on."
    },
    renewal_fails: %{
      label: "Monthly, card fails at renewal",
      plan: "pro-monthly",
      buyer: "Clock Failing",
      expect:
        "Move a month: the renewal fails and it goes past_due; Stripe tries again over the next weeks, then it ends."
    },
    trial_then_paid: %{
      label: "14-day trial, then paid",
      plan: "team-monthly",
      buyer: "Clock Trial",
      expect: "Move 15 days: the trial ends, the first invoice is paid, trialing becomes active."
    },
    trial_then_fails: %{
      label: "14-day trial, card fails",
      plan: "team-monthly",
      buyer: "Clock Trial Fails",
      expect: "Move 15 days: the trial ends, the first charge fails and it goes past_due."
    }
  ]

  @steps [
    {"1d", 1, "+1 day"},
    {"15d", 15, "+15 days"},
    {"1m", 31, "+1 month"},
    {"1y", 366, "+1 year"}
  ]

  # How many times the panel asks a moving clock again, a moment apart, before it stops asking.
  @checks 90

  @impl true
  def mount(socket), do: {:ok, assign(socket, loaded?: false, moving: MapSet.new())}

  @impl true
  def update(%{check: clock_id, tries: tries}, socket), do: {:ok, check(socket, clock_id, tries)}

  def update(assigns, socket) do
    socket = assign(socket, id: assigns.id, tenant: assigns.tenant)

    case socket.assigns.loaded? do
      true -> {:ok, socket}
      false -> {:ok, socket |> assign(loaded?: true) |> load()}
    end
  end

  @impl true
  def handle_event("start", %{"scenario" => scenario}, socket) do
    case scenario(scenario) do
      {:ok, name, spec} ->
        {:noreply, socket |> start(name, spec) |> load()}

      :error ->
        {:noreply, say(socket, :error, "Choose a situation from the list.")}
    end
  end

  def handle_event("advance", %{"clock" => clock_id, "days" => days}, socket) do
    {days, ""} = Integer.parse(days)

    with {:ok, %TestClock{frozen_time: at}} <- TestClock.fetch(socket.assigns.tenant, clock_id),
         {:ok, _moving} <-
           TestClock.advance(socket.assigns.tenant, clock_id, DateTime.add(at, days, :day)) do
      send_update_after(
        __MODULE__,
        %{id: socket.assigns.id, check: clock_id, tries: @checks},
        1_000
      )

      {:noreply,
       socket
       |> update(:moving, &MapSet.put(&1, clock_id))
       |> say(:info, "Stripe is moving the clock #{days} days forward...")}
    else
      {:error, error} -> {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("delete", %{"clock" => clock_id}, socket) do
    with :ok <- TestClock.delete(socket.assigns.tenant, clock_id),
         {:ok, run} <- run(clock_id) do
      Ash.destroy!(run, authorize?: false)

      {:noreply,
       socket |> load() |> say(:info, "Clock deleted, with its customer and subscription.")}
    else
      {:error, error} -> {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="test-clocks" class="space-y-3">
      <.section_title icon="hero-clock" title="Test clocks" />
      <p class="text-sm opacity-70">
        A subscription on its own Stripe test clock. Move the clock forward and watch the
        subscription renew, fail or end its trial, in the table above and here.
      </p>
      <.hint>MishkaPay.Providers.Stripe.TestClock</.hint>

      <form phx-submit="start" phx-target={@myself} class="flex flex-wrap gap-2 items-end">
        <select name="scenario" class="select select-sm" data-testid="clock-start-scenario">
          <option :for={{name, spec} <- scenarios()} value={name}>{spec.label}</option>
        </select>
        <button
          class="btn btn-sm btn-primary"
          phx-disable-with="Setting it up at Stripe..."
          data-testid="clock-start-submit"
        >
          Start on a new clock
        </button>
        <button
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click="refresh"
          phx-target={@myself}
          data-testid="clock-refresh"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Refresh
        </button>
      </form>

      <p :if={@runs == []} class="text-sm opacity-70" data-testid="clock-runs-empty">
        No clocks yet. Start one above.
      </p>

      <div class="grid gap-3 lg:grid-cols-2">
        <div
          :for={run <- @runs}
          class="card bg-base-200"
          data-testid="clock-run"
          data-clock-id={run.clock_id}
          data-scenario={run.scenario}
          data-sub-status={
            @subscriptions[run.subscription_id] && @subscriptions[run.subscription_id].status
          }
          data-clock-status={clock_status(@clocks, run.clock_id, @moving)}
        >
          <div class="card-body gap-2 p-4">
            <div class="flex flex-wrap items-center gap-2">
              <h3 class="font-medium flex-1">{label(run.scenario)}</h3>
              <span class="badge badge-sm" data-testid="clock-status">
                {clock_status(@clocks, run.clock_id, @moving)}
              </span>
            </div>
            <p class="text-xs opacity-70" data-testid="clock-expect">{expect(run.scenario)}</p>
            <dl class="grid grid-cols-2 gap-y-1 text-sm">
              <dt class="opacity-70">Clock time</dt>
              <dd class="text-xs" data-testid="clock-time">{clock_time(@clocks, run.clock_id)}</dd>
              <dt class="opacity-70">Subscription</dt>
              <dd class="font-mono text-xs break-all">{run.subscription_id}</dd>
              <dt class="opacity-70">Status</dt>
              <dd data-testid="clock-sub-status">
                <span class="badge badge-sm">
                  {(@subscriptions[run.subscription_id] && @subscriptions[run.subscription_id].status) ||
                    "–"}
                </span>
              </dd>
              <dt class="opacity-70">Period ends</dt>
              <dd class="text-xs">
                {@subscriptions[run.subscription_id] &&
                  time(@subscriptions[run.subscription_id].current_period_end)}
              </dd>
            </dl>
            <div class="flex flex-wrap gap-1">
              <button
                :for={{key, days, text} <- steps()}
                class="btn btn-xs"
                phx-click="advance"
                phx-value-clock={run.clock_id}
                phx-value-days={days}
                phx-target={@myself}
                disabled={MapSet.member?(@moving, run.clock_id)}
                data-testid={"clock-advance-#{key}"}
              >
                {text}
              </button>
              <button
                class="btn btn-xs btn-ghost text-error"
                phx-click="delete"
                phx-value-clock={run.clock_id}
                phx-target={@myself}
                data-confirm="Delete this clock with its customer and subscription at Stripe?"
                data-testid="clock-delete"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # A new clock, a customer living on it with the situation's card, and a subscription to the
  # situation's plan; then the row through Mishka Pay's own sync.
  defp start(socket, name, spec) do
    tenant = socket.assigns.tenant
    plan = Shop.Catalog.fetch(spec.plan)

    with {:ok, clock} <- TestClock.create(tenant, name: spec.label) do
      customer = StripeSandbox.customer(spec.buyer, clock: clock.id)
      StripeSandbox.default_card(customer, first_card(name))
      subscription_id = StripeSandbox.subscribe(plan, customer)
      then_card(name, customer)

      Ash.create!(
        ClockRun,
        %{
          clock_id: clock.id,
          scenario: name,
          subscription_id: subscription_id,
          buyer: spec.buyer
        },
        action: :start,
        authorize?: false
      )

      sync(subscription_id, tenant)

      say(
        socket,
        :info,
        "#{spec.label}: set up on its own clock. Move it forward to see it change."
      )
    else
      {:error, error} -> say(socket, :error, MishkaPay.Ash.message(error))
    end
  end

  # The card the first charge (or the trial's end) is paid with; a renewal that must fail gets a
  # failing card only after its first invoice is paid.
  defp first_card(:trial_then_fails), do: "pm_card_chargeCustomerFail"
  defp first_card(_paid_first), do: "pm_card_mastercard"

  defp then_card(:renewal_fails, customer),
    do: StripeSandbox.default_card(customer, "pm_card_chargeCustomerFail")

  defp then_card(_other, _customer), do: :ok

  # Asks a moving clock again a moment later until it is ready, then reads its subscription again.
  defp check(socket, clock_id, tries) do
    case TestClock.fetch(socket.assigns.tenant, clock_id) do
      {:ok, %TestClock{status: :ready}} ->
        with {:ok, run} <- run(clock_id), do: sync(run.subscription_id, socket.assigns.tenant)

        socket
        |> update(:moving, &MapSet.delete(&1, clock_id))
        |> load()
        |> say(:info, "The clock has moved: the subscription is read again from Stripe.")

      {:ok, _still_moving} when tries > 0 ->
        send_update_after(
          __MODULE__,
          %{id: socket.assigns.id, check: clock_id, tries: tries - 1},
          1_000
        )

        socket

      _gave_up_or_error ->
        socket
        |> update(:moving, &MapSet.delete(&1, clock_id))
        |> say(:error, "The clock is still moving at Stripe. Press Refresh in a moment.")
    end
  end

  defp sync(subscription_id, tenant) do
    Ash.create(
      Subscription,
      %{provider: "stripe", subscription_id: subscription_id, tenant: tenant},
      action: :sync,
      authorize?: false
    )
  end

  # The runs from the database, their clocks from Stripe in one request, their subscriptions in one
  # query.
  defp load(socket) do
    runs = ClockRun |> Ash.Query.sort(inserted_at: :desc) |> Ash.read!(authorize?: false)
    ids = Enum.map(runs, & &1.subscription_id)

    subscriptions =
      Subscription
      |> Ash.Query.filter(provider_id in ^ids)
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.provider_id, &1})

    clocks =
      case TestClock.list(socket.assigns.tenant) do
        {:ok, clocks} -> Map.new(clocks, &{&1.id, &1})
        {:error, _no_keys} -> %{}
      end

    assign(socket, runs: runs, subscriptions: subscriptions, clocks: clocks)
  end

  defp run(clock_id) do
    case ClockRun |> Ash.Query.filter(clock_id == ^clock_id) |> Ash.read_one(authorize?: false) do
      {:ok, %ClockRun{} = run} -> {:ok, run}
      _none -> {:error, "This clock is not one the panel set up."}
    end
  end

  defp scenario(value) do
    case Enum.find(@scenarios, fn {name, _spec} -> Atom.to_string(name) == value end) do
      {name, spec} -> {:ok, name, spec}
      nil -> :error
    end
  end

  defp scenarios, do: @scenarios
  defp steps, do: @steps

  defp label(name), do: @scenarios[name].label
  defp expect(name), do: @scenarios[name].expect

  defp clock_status(clocks, id, moving) do
    cond do
      MapSet.member?(moving, id) -> "moving"
      clocks[id] -> to_string(clocks[id].status)
      true -> "gone at Stripe"
    end
  end

  defp clock_time(clocks, id), do: (clocks[id] && time(clocks[id].frozen_time)) || "–"

  defp time(nil), do: "–"
  defp time(%DateTime{} = time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M")

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end
end

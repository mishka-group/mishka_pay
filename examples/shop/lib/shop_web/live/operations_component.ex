defmodule ShopWeb.OperationsComponent do
  @moduledoc """
  Running the site: every setup check for it (`MishkaPay.Check.run/1`: provider, keys, webhook
  secret and endpoint, listeners, inbox), its Stripe webhook endpoint for a URL
  (`MishkaPay.Providers.Stripe.WebhookEndpoint.check/3`, made or completed only on a click with
  `ensure/3`), of the kind the site uses (its keys' `:events` and `:webhook_api`: a thin event
  destination by default) or another one picked, Stripe's events of the last hour of that kind
  (`MishkaPay.list_events/3`), delivering again what a site missed (`MishkaPay.replay_events/3`),
  and whether Stripe has a newer API version than the one Mishka Pay pins
  (`MishkaPay.Providers.Stripe.latest_version/0` and `version/0`).
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Providers.Stripe.WebhookEndpoint

  @windows %{"15m" => 15 * 60, "1h" => 3600, "1d" => 86_400}

  # The endpoint kinds a site can pick, each with the options `WebhookEndpoint` takes.
  @kinds [
    {"thin", "Thin events, event destination (API v2)", [events: :thin, api: :v2]},
    {"snapshot", "Snapshot events, event destination (API v2)", [events: :snapshot, api: :v2]},
    {"snapshot_v1", "Snapshot events, v1 webhook endpoint", [events: :snapshot, api: :v1]}
  ]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       url: nil,
       checks: nil,
       endpoint: nil,
       events: nil,
       replayed: nil,
       replaying: false,
       window: "1h",
       versions: nil,
       site_kind: nil,
       kind: nil,
       notice: nil,
       error: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    url = socket.assigns.url || "#{ShopWeb.Endpoint.url()}/pay/webhooks/stripe/#{assigns.tenant}"
    site_kind = socket.assigns.site_kind || site_kind(assigns.tenant)

    {:ok,
     assign(socket,
       tenant: assigns.tenant,
       url: url,
       site_kind: site_kind,
       kind: socket.assigns.kind || site_kind
     )}
  end

  @impl true
  def handle_event("setup", %{"intent" => "checks", "url" => url} = params, socket) do
    url = blank(url)
    socket = assign(socket, kind: kind(params["kind"]))

    checks =
      MishkaPay.Check.run(
        provider: "stripe",
        tenant: socket.assigns.tenant,
        webhook_url: url,
        domain: Shop.Pay
      )

    {:noreply, assign(socket, checks: checks, url: url || "", notice: nil, error: nil)}
  end

  def handle_event("setup", %{"intent" => intent, "url" => url} = params, socket) do
    socket = assign(socket, url: String.trim(url), kind: kind(params["kind"]))

    case blank(url) do
      nil -> {:noreply, assign(socket, error: "Type the webhook URL first.", notice: nil)}
      url when intent == "ensure" -> {:noreply, ensure(socket, url)}
      url -> {:noreply, check(socket, url)}
    end
  end

  def handle_event("events", _params, socket) do
    since = DateTime.add(DateTime.utc_now(), -3600, :second)

    opts = [since: since, limit: 20, events: events_of(socket.assigns.kind)]

    case MishkaPay.list_events("stripe", socket.assigns.tenant, opts) do
      {:ok, page} -> {:noreply, assign(socket, events: page.items, notice: nil, error: nil)}
      {:error, error} -> {:noreply, failed(socket, error)}
    end
  end

  # The window picked is kept, so reading the events or a check does not reset it.
  def handle_event("pick_window", params, socket),
    do: {:noreply, assign(socket, window: window(params["window"]))}

  # Replaying an hour of events can take a while: it runs in its own task, so the page stays live.
  def handle_event("replay", params, socket) do
    socket = assign(socket, window: window(params["window"]))
    seconds = Map.fetch!(@windows, socket.assigns.window)
    since = DateTime.add(DateTime.utc_now(), -seconds, :second)
    tenant = socket.assigns.tenant
    opts = [since: since, events: events_of(socket.assigns.kind)]

    {:noreply,
     socket
     |> assign(replayed: nil, replaying: true, notice: nil, error: nil)
     |> start_async(:replay, fn -> MishkaPay.replay_events("stripe", tenant, opts) end)}
  end

  def handle_event("version", _params, socket) do
    case Stripe.latest_version() do
      {:ok, latest} ->
        {:noreply, assign(socket, versions: {Stripe.version(), latest}, notice: nil, error: nil)}

      {:error, error} ->
        {:noreply, socket |> assign(versions: nil) |> failed(error)}
    end
  end

  @impl true
  def handle_async(:replay, {:ok, {:ok, replayed}}, socket) do
    {:noreply,
     socket
     |> assign(replayed: replayed, replaying: false)
     |> done("Delivered #{replayed.delivered} again, #{length(replayed.failed)} failed.")}
  end

  def handle_async(:replay, {:ok, {:error, error}}, socket),
    do: {:noreply, socket |> assign(replayed: nil, replaying: false) |> failed(error)}

  def handle_async(:replay, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       replayed: nil,
       replaying: false,
       notice: nil,
       error: "The replay stopped before it ended. Try a shorter window."
     )}
  end

  defp check(socket, url) do
    case WebhookEndpoint.check(socket.assigns.tenant, url, kind_opts(socket.assigns.kind)) do
      {:ok, found} -> assign(socket, endpoint: found, notice: nil, error: nil)
      {:error, error} -> socket |> assign(endpoint: nil) |> failed(error)
    end
  end

  # The signing secret Stripe answers for a new endpoint is never shown or kept here.
  defp ensure(socket, url) do
    case WebhookEndpoint.ensure(socket.assigns.tenant, url, kind_opts(socket.assigns.kind)) do
      {:ok, endpoint} ->
        message =
          case endpoint.secret do
            nil ->
              "Endpoint #{endpoint.id} sends every event Mishka Pay acts on."

            _secret ->
              "Endpoint #{endpoint.id} made. Put its signing secret, shown in the Stripe Dashboard, in STRIPE_WEBHOOK_SECRET."
          end

        socket
        |> assign(endpoint: %{endpoint: %{endpoint | secret: nil}, missing: []})
        |> done(message)

      {:error, error} ->
        failed(socket, error)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="operations" class="space-y-4">
      <.section_title icon="hero-wrench-screwdriver" title="Operations" />
      <p class="text-sm opacity-70">
        Is this site ready to take money? Check its setup, its webhook endpoint at Stripe, the
        events Stripe sent, and the API version.
      </p>
      <.hint>
        MishkaPay.Check.run/1, Stripe.WebhookEndpoint.check/3, ensure/3, MishkaPay.list_events/3, replay_events/3
      </.hint>
      <p class="text-sm" data-testid="operations-site-kind" data-kind={@site_kind}>
        This site takes <strong>{kind_label(@site_kind)}</strong>
        (its keys' <code>events</code>
        and <code>webhook_api</code>). The webhook takes either kind;
        a thin event names its object, and Mishka Pay reads the rest.
      </p>

      <div
        :if={@notice}
        role="status"
        class="alert alert-success py-2"
        data-testid="operations-notice"
      >
        {@notice}
      </div>
      <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="operations-error">
        {@error}
      </div>

      <form
        id="operations-setup"
        phx-submit="setup"
        phx-target={@myself}
        class="card bg-base-200"
        data-testid="operations-setup-form"
      >
        <div class="card-body gap-3">
          <label class="fieldset">
            <span class="fieldset-legend">Webhook URL (Stripe must reach it)</span>
            <input name="url" value={@url} class="input input-sm w-full" data-testid="operations-url" />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Kind of endpoint (also the events read and replayed)</span>
            <select name="kind" class="select select-sm w-full" data-testid="operations-kind">
              <option
                :for={{value, label, _opts} <- kinds()}
                value={value}
                selected={value == @kind}
              >
                {label}
              </option>
            </select>
          </label>
          <div class="flex flex-wrap gap-2">
            <button
              name="intent"
              value="checks"
              class="btn btn-sm btn-primary"
              phx-disable-with="Checking..."
              data-testid="operations-checks"
            >
              Run every check
            </button>
            <button
              name="intent"
              value="endpoint"
              class="btn btn-sm"
              phx-disable-with="Asking Stripe..."
              data-testid="operations-endpoint"
            >
              Check the endpoint
            </button>
            <button
              name="intent"
              value="ensure"
              class="btn btn-sm btn-outline"
              data-confirm="Make or complete the webhook endpoint at this URL in your Stripe account?"
              phx-disable-with="Asking Stripe..."
              data-testid="operations-ensure"
            >
              Make endpoint
            </button>
          </div>

          <ul :if={@checks} class="space-y-1 text-sm" data-testid="check-rows">
            <li
              :for={{name, result} <- @checks}
              class="flex flex-wrap items-center gap-2"
              data-testid="check-row"
              data-check={name}
              data-ok={to_string(result == :ok)}
            >
              <span class={["badge badge-sm", (result == :ok && "badge-success") || "badge-error"]}>
                {if result == :ok, do: "ok", else: "fail"}
              </span>
              <code>{name}</code>
              <span :if={result != :ok} class="opacity-80" data-testid="check-reason">{reason(result)}</span>
            </li>
          </ul>

          <div
            :if={@endpoint}
            class="rounded-box bg-base-100 p-3 text-sm"
            data-testid="endpoint-result"
          >
            <p :if={!@endpoint.endpoint} data-testid="endpoint-none">
              No endpoint of this kind at this URL. "Make endpoint" makes one.
            </p>
            <dl :if={@endpoint.endpoint} class="grid grid-cols-2 gap-y-1 max-w-xl">
              <dt class="opacity-70">Endpoint</dt>
              <dd class="font-mono text-xs" data-testid="endpoint-id">{@endpoint.endpoint.id}</dd>
              <dt class="opacity-70">Events</dt>
              <dd data-testid="endpoint-events">{@endpoint.endpoint.events}</dd>
              <dt class="opacity-70">Changed through</dt>
              <dd data-testid="endpoint-api">API {@endpoint.endpoint.api}</dd>
              <dt class="opacity-70">Events from</dt>
              <dd data-testid="endpoint-from">{Enum.join(@endpoint.endpoint.events_from, ", ")}</dd>
              <dt class="opacity-70">State</dt>
              <dd data-testid="endpoint-status">{@endpoint.endpoint.status}</dd>
              <dt class="opacity-70">API version</dt>
              <dd>{@endpoint.endpoint.api_version || "none (thin events carry no version)"}</dd>
            </dl>
            <p :if={@endpoint.missing == []} class="text-success" data-testid="endpoint-complete">
              It sends every event Mishka Pay acts on.
            </p>
            <p :if={@endpoint.missing != []} data-testid="endpoint-missing">
              Missing {length(@endpoint.missing)} events: {Enum.join(@endpoint.missing, ", ")}
            </p>
          </div>
        </div>
      </form>

      <div class="grid gap-4 lg:grid-cols-2">
        <div class="card bg-base-200">
          <div class="card-body gap-3">
            <div class="flex flex-wrap items-center gap-2">
              <h3 class="font-medium flex-1">Events of the last hour</h3>
              <button
                class="btn btn-sm"
                phx-click="events"
                phx-target={@myself}
                phx-disable-with="Asking Stripe..."
                data-testid="operations-events"
              >
                Read events
              </button>
            </div>
            <form
              id="operations-replay"
              phx-change="pick_window"
              phx-submit="replay"
              phx-target={@myself}
              class="join"
              data-testid="operations-replay-form"
            >
              <select
                name="window"
                class="select select-sm join-item"
                data-testid="operations-replay-window"
              >
                <option
                  :for={
                    {value, label} <- [
                      {"15m", "15 minutes ago"},
                      {"1h", "One hour ago"},
                      {"1d", "One day ago"}
                    ]
                  }
                  value={value}
                  selected={@window == value}
                >
                  {label}
                </option>
              </select>
              <button
                class="btn btn-sm join-item"
                phx-disable-with="Delivering..."
                disabled={@replaying}
                data-testid="operations-replay"
              >
                Replay since
              </button>
            </form>
            <p :if={@replaying} class="text-sm" data-testid="replay-running">
              Delivering the events again…
            </p>
            <p :if={@replayed} class="text-sm" data-testid="operations-replayed">
              <span data-testid="replay-delivered">{@replayed.delivered}</span>
              delivered, <span data-testid="replay-failed">{length(@replayed.failed)}</span>
              failed
              <span :for={{id, _reason} <- @replayed.failed} class="font-mono text-xs">{id}</span>
            </p>
            <ul :if={@events} class="text-sm space-y-1" data-testid="event-rows">
              <li :if={@events == []} class="opacity-70" data-testid="events-empty">
                No events in the last hour.
              </li>
              <li
                :for={event <- @events}
                class="flex flex-wrap gap-2"
                data-testid="event-row"
                data-event-id={event.id}
              >
                <code>{event.type}</code>
                <span class="font-mono text-xs opacity-70">{event.object_id}</span>
                <span class="text-xs opacity-60">{time(event.created_at)}</span>
              </li>
            </ul>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body gap-3">
            <div class="flex flex-wrap items-center gap-2">
              <h3 class="font-medium flex-1">Stripe API version</h3>
              <button
                class="btn btn-sm"
                phx-click="version"
                phx-target={@myself}
                phx-disable-with="Asking GitHub..."
                data-testid="operations-version"
              >
                Check version
              </button>
            </div>
            <dl :if={@versions} class="grid grid-cols-2 gap-y-1 text-sm" data-testid="version-result">
              <dt class="opacity-70">Mishka Pay pins</dt>
              <dd class="font-mono text-xs" data-testid="version-pinned">{elem(@versions, 0)}</dd>
              <dt class="opacity-70">Stripe's newest</dt>
              <dd class="font-mono text-xs" data-testid="version-latest">{elem(@versions, 1)}</dd>
              <dt class="opacity-70">Up to date</dt>
              <dd data-testid="version-current">
                {if elem(@versions, 0) == elem(@versions, 1),
                  do: "yes",
                  else: "no, a newer one is out"}
              </dd>
            </dl>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp reason({:error, reason}), do: reason
  defp reason(_ok), do: ""

  # The kind the site's keys set up: thin events on an event destination unless they say other.
  defp site_kind(tenant) do
    case MishkaPay.Credentials.fetch("stripe", tenant) do
      {:ok, %{events: :snapshot, webhook_api: :v1}} -> "snapshot_v1"
      {:ok, %{events: :snapshot}} -> "snapshot"
      _thin_or_no_keys -> "thin"
    end
  end

  # A kind the form does not offer falls back to thin.
  defp kind(value) do
    case List.keyfind(@kinds, value, 0) do
      nil -> "thin"
      {kind, _label, _opts} -> kind
    end
  end

  defp kinds, do: @kinds
  defp kind_opts(kind), do: @kinds |> List.keyfind(kind, 0) |> elem(2)
  defp events_of(kind), do: kind |> kind_opts() |> Keyword.fetch!(:events)
  defp kind_label(kind), do: @kinds |> List.keyfind(kind, 0) |> elem(1)

  defp time(nil), do: ""
  defp time(%DateTime{} = time), do: Calendar.strftime(time, "%H:%M:%S")

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank(_none), do: nil

  # A window the form does not offer falls back to an hour.
  defp window(window) when is_map_key(@windows, window), do: window
  defp window(_other), do: "1h"

  defp done(socket, message), do: assign(socket, notice: message, error: nil)

  defp failed(socket, error), do: assign(socket, error: MishkaPay.Ash.message(error), notice: nil)
end

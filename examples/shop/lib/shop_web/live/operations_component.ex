defmodule ShopWeb.OperationsComponent do
  @moduledoc """
  Running the site: every setup check for it (`MishkaPay.Check.run/1`: provider, keys, webhook
  secret and endpoint, listeners, inbox), its Stripe webhook endpoint for a URL
  (`MishkaPay.Providers.Stripe.WebhookEndpoint.check/2`, made or completed only on a click with
  `ensure/2`), Stripe's events of the last hour (`MishkaPay.list_events/3`), delivering again
  what a site missed (`MishkaPay.replay_events/3`), and whether Stripe has a newer API version
  than the one Mishka Pay pins (`MishkaPay.Providers.Stripe.latest_version/0` and `version/0`).
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Providers.Stripe.WebhookEndpoint

  @windows %{"15m" => 15 * 60, "1h" => 3600, "1d" => 86_400}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       url: nil,
       checks: nil,
       endpoint: nil,
       events: nil,
       replayed: nil,
       versions: nil,
       notice: nil,
       error: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    url = socket.assigns.url || "#{ShopWeb.Endpoint.url()}/pay/webhooks/stripe/#{assigns.tenant}"
    {:ok, assign(socket, tenant: assigns.tenant, url: url)}
  end

  @impl true
  def handle_event("setup", %{"intent" => "checks", "url" => url}, socket) do
    url = blank(url)

    checks =
      MishkaPay.Check.run(
        provider: "stripe",
        tenant: socket.assigns.tenant,
        webhook_url: url,
        domain: Shop.Pay
      )

    {:noreply, assign(socket, checks: checks, url: url || "", notice: nil, error: nil)}
  end

  def handle_event("setup", %{"intent" => intent, "url" => url}, socket) do
    socket = assign(socket, url: String.trim(url))

    case blank(url) do
      nil -> {:noreply, assign(socket, error: "Type the webhook URL first.", notice: nil)}
      url when intent == "ensure" -> {:noreply, ensure(socket, url)}
      url -> {:noreply, check(socket, url)}
    end
  end

  def handle_event("events", _params, socket) do
    since = DateTime.add(DateTime.utc_now(), -3600, :second)

    case MishkaPay.list_events("stripe", socket.assigns.tenant, since: since, limit: 20) do
      {:ok, page} -> {:noreply, assign(socket, events: page.items, notice: nil, error: nil)}
      {:error, error} -> {:noreply, failed(socket, error)}
    end
  end

  def handle_event("replay", %{"window" => window}, socket) do
    since = DateTime.add(DateTime.utc_now(), -Map.get(@windows, window, 3600), :second)

    case MishkaPay.replay_events("stripe", socket.assigns.tenant, since: since) do
      {:ok, replayed} ->
        {:noreply,
         socket
         |> assign(replayed: replayed)
         |> done("Delivered #{replayed.delivered} again, #{length(replayed.failed)} failed.")}

      {:error, error} ->
        {:noreply, socket |> assign(replayed: nil) |> failed(error)}
    end
  end

  def handle_event("version", _params, socket) do
    case Stripe.latest_version() do
      {:ok, latest} ->
        {:noreply, assign(socket, versions: {Stripe.version(), latest}, notice: nil, error: nil)}

      {:error, error} ->
        {:noreply, socket |> assign(versions: nil) |> failed(error)}
    end
  end

  defp check(socket, url) do
    case WebhookEndpoint.check(socket.assigns.tenant, url) do
      {:ok, found} -> assign(socket, endpoint: found, notice: nil, error: nil)
      {:error, error} -> socket |> assign(endpoint: nil) |> failed(error)
    end
  end

  # The signing secret Stripe answers for a new endpoint is never shown or kept here.
  defp ensure(socket, url) do
    case WebhookEndpoint.ensure(socket.assigns.tenant, url) do
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
        MishkaPay.Check.run/1, Stripe.WebhookEndpoint.check/2, MishkaPay.list_events/3, replay_events/3
      </.hint>

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
              No endpoint at this URL. "Make endpoint" makes one.
            </p>
            <dl :if={@endpoint.endpoint} class="grid grid-cols-2 gap-y-1 max-w-xl">
              <dt class="opacity-70">Endpoint</dt>
              <dd class="font-mono text-xs" data-testid="endpoint-id">{@endpoint.endpoint.id}</dd>
              <dt class="opacity-70">State</dt>
              <dd data-testid="endpoint-status">{@endpoint.endpoint.status}</dd>
              <dt class="opacity-70">API version</dt>
              <dd>{@endpoint.endpoint.api_version}</dd>
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
                <option value="15m">15 minutes ago</option>
                <option value="1h" selected>One hour ago</option>
                <option value="1d">One day ago</option>
              </select>
              <button
                class="btn btn-sm join-item"
                phx-disable-with="Delivering..."
                data-testid="operations-replay"
              >
                Replay since
              </button>
            </form>
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

  defp time(nil), do: ""
  defp time(%DateTime{} = time), do: Calendar.strftime(time, "%H:%M:%S")

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

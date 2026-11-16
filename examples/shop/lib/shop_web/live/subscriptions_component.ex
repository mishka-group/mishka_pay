defmodule ShopWeb.SubscriptionsComponent do
  @moduledoc """
  The subscriptions part of the demo shop: every subscription the shop keeps, live, and one at a
  time in detail: the stored row beside the subscription read live from Stripe
  (`MishkaPay.fetch_subscription/3`), its invoices (`MishkaPay.list_invoices/3`), and the `:cancel`
  (at the period's end or now), `:resume` and `:sync` actions. The page sends it each changed
  subscription (`changed`) and a subscription to open (`open`).
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  alias Shop.Pay.Subscription

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, selected: nil, loaded?: false, preview: nil, change: nil)}

  @impl true
  def update(%{changed: record}, socket) do
    {:ok, socket |> stream_insert(:subscriptions, record, at: 0) |> reselect(record)}
  end

  def update(%{open: id}, socket), do: {:ok, select(socket, id)}

  def update(assigns, socket) do
    socket = assign(socket, tenant: assigns.tenant, plans: plans())

    case socket.assigns.loaded? do
      true -> {:ok, socket}
      false -> {:ok, socket |> assign(loaded?: true) |> stream(:subscriptions, newest())}
    end
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket),
    do: {:noreply, socket |> assign(preview: nil, change: nil) |> select(id)}

  def handle_event("close", _params, socket),
    do: {:noreply, assign(socket, selected: nil, preview: nil, change: nil)}

  # The change the form describes, previewed first: the preview keeps its proration date, so
  # applying it bills exactly what it showed.
  def handle_event("preview_change", params, socket) do
    row = socket.assigns.selected
    change = change_attrs(params, row)

    case MishkaPay.preview_subscription_change(change) do
      {:ok, invoice} ->
        {:noreply, assign(socket, preview: invoice, change: change)}

      {:error, error} ->
        {:noreply,
         socket |> assign(preview: nil, change: nil) |> say(:error, MishkaPay.Ash.message(error))}
    end
  end

  # Only the previewed subscription's own change applies, with the preview's proration date.
  def handle_event(
        "apply_change",
        _params,
        %{assigns: %{change: %{subscription_id: id} = change, selected: %{provider_id: id}}} =
          socket
      ) do
    args = Map.drop(change, [:provider, :tenant, :subscription_id])
    row = Ash.get!(Subscription, socket.assigns.selected.id, authorize?: false)

    case row |> Ash.Changeset.for_update(:change, args) |> Ash.update(authorize?: false) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(preview: nil, change: nil)
         |> stream_insert(:subscriptions, updated, at: 0)
         |> select(updated.id)
         |> say(:info, "Changed on Stripe, billed as the preview showed.")}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("apply_change", _params, socket) do
    {:noreply,
     socket |> assign(preview: nil, change: nil) |> say(:error, "Preview the change again first.")}
  end

  def handle_event("cancel_change", _params, socket),
    do: {:noreply, assign(socket, preview: nil, change: nil)}

  def handle_event("pause", %{"subscription" => id} = params, socket) do
    args =
      %{behavior: params["behavior"], resumes_at: date(params["resumes_at"])}
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    run_action(socket, id, :pause, args, "Collection paused: no charges until it resumes.")
  end

  def handle_event("resume_collection", %{"id" => id}, socket),
    do: run_action(socket, id, :resume_collection, %{}, "Collection goes on again.")

  def handle_event("act", %{"id" => id, "action" => action}, socket) do
    row = Ash.get!(Subscription, id, authorize?: false)

    case perform(row, action) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> stream_insert(:subscriptions, updated, at: 0)
         |> select(updated.id)
         |> say(:info, done(action))}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("read", %{"subscription_id" => value}, socket) do
    with {:ok, id} <- subscription_id(value),
         {:ok, row} <- sync(id, socket.assigns.tenant) do
      {:noreply,
       socket
       |> stream_insert(:subscriptions, row, at: 0)
       |> select(row.id)
       |> say(:info, "Subscription read from Stripe and saved.")}
    else
      {:error, error} ->
        {:noreply, socket |> assign(selected: nil) |> say(:error, MishkaPay.Ash.message(error))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="subscriptions" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <.section_title icon="hero-arrow-path-rounded-square" title="Subscriptions" />
        <form phx-submit="read" phx-target={@myself} class="join" data-testid="read-subscription-form">
          <input
            name="subscription_id"
            placeholder="sub_... from the sandbox"
            class="input input-sm join-item"
            data-testid="read-subscription-input"
          />
          <button class="btn btn-sm join-item" data-testid="read-subscription-submit">
            Read subscription
          </button>
        </form>
      </div>

      <div class="overflow-x-auto rounded-box border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>Plan</th>
              <th>Buyer</th>
              <th>Price</th>
              <th>Status</th>
              <th>Period ends</th>
            </tr>
          </thead>
          <tbody id="subscriptions" phx-update="stream" data-testid="subscription-rows">
            <tr id="subscriptions-empty" class="only:table-row hidden">
              <td colspan="5" class="text-center opacity-70">
                No subscriptions yet. Subscribe to a plan above.
              </td>
            </tr>
            <tr
              :for={{dom_id, sub} <- @streams.subscriptions}
              id={dom_id}
              class="hover:bg-base-200 cursor-pointer"
              phx-click="select"
              phx-value-id={sub.id}
              phx-target={@myself}
              data-testid="subscription-row"
              data-subscription-id={sub.provider_id}
              data-status={sub.status}
            >
              <td>
                <div class="font-medium">{sub.plan || "Subscription"}</div>
                <div class="text-xs opacity-60 font-mono">{sub.provider_id}</div>
              </td>
              <td class="text-sm">
                <div>{sub.customer_name || "–"}</div>
                <div class="text-xs opacity-60">{sub.customer_email}</div>
              </td>
              <td class="text-sm">{price(sub)}</td>
              <td>
                <.sub_status status={sub.status} />
                <div :if={active?(sub) and sub.cancel_at_period_end} class="text-xs text-warning">
                  ends at period end
                </div>
              </td>
              <td class="text-xs opacity-70" data-testid="subscription-period">
                <.period sub={sub} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.details
        :if={@selected}
        selected={@selected}
        live={@live}
        plans={@plans}
        preview={@preview}
        myself={@myself}
      />
    </section>
    """
  end

  attr :selected, :map, required: true
  attr :live, :any, required: true
  attr :plans, :list, required: true
  attr :preview, :any, required: true
  attr :myself, :any, required: true

  defp details(assigns) do
    ~H"""
    <div
      class="card bg-base-200 border border-primary/40"
      data-testid="subscription-details"
      data-subscription-id={@selected.provider_id}
    >
      <div class="card-body gap-4">
        <div class="flex flex-wrap items-center gap-3">
          <h3 class="card-title flex-1 min-w-0 flex-wrap">
            {@selected.plan || "Subscription"}
            <code class="text-sm opacity-70 break-all">{@selected.provider_id}</code>
          </h3>
          <a
            href={"https://dashboard.stripe.com/test/subscriptions/#{@selected.provider_id}"}
            target="_blank"
            class="btn btn-ghost btn-sm shrink-0"
            data-testid="subscription-stripe-link"
          >
            Stripe <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </a>
          <button
            class="btn btn-ghost btn-sm shrink-0"
            phx-click="close"
            phx-target={@myself}
            aria-label="Close"
            data-testid="subscription-close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <div class="rounded-box bg-base-100 p-4" data-testid="subscription-stored">
            <h4 class="font-medium">In the shop's database</h4>
            <.hint>Shop.Pay.Subscription</.hint>
            <dl class="grid grid-cols-2 gap-y-1 text-sm mt-2">
              <dt class="opacity-70">Status</dt>
              <dd data-testid="sub-stored-status"><.sub_status status={@selected.status} /></dd>
              <dt class="opacity-70">Price</dt>
              <dd data-testid="sub-stored-price">{price(@selected)}</dd>
              <dt class="opacity-70">Buyer</dt>
              <dd>
                {@selected.customer_name || "–"}
                <span class="block text-xs opacity-70">{@selected.customer_email}</span>
              </dd>
              <dt class="opacity-70">{if active?(@selected), do: "Period ends", else: "Ended"}</dt>
              <dd class="text-xs" data-testid="sub-stored-period-end">
                {if active?(@selected),
                  do: time(@selected.current_period_end),
                  else: time(ended_at(@selected))}
              </dd>
              <dt :if={active?(@selected) and @selected.canceled_at} class="opacity-70">
                Canceled at
              </dt>
              <dd :if={active?(@selected) and @selected.canceled_at} class="text-xs">
                {time(@selected.canceled_at)}
              </dd>
              <dt :if={active?(@selected)} class="opacity-70">Ends then</dt>
              <dd :if={active?(@selected)} data-testid="sub-stored-cancel">
                {yes_no(@selected.cancel_at_period_end)}
              </dd>
              <dt :if={@selected.trial_end} class="opacity-70">Trial ends</dt>
              <dd :if={@selected.trial_end} class="text-xs">{time(@selected.trial_end)}</dd>
              <dt class="opacity-70">Reference</dt>
              <dd class="font-mono text-xs break-all">{@selected.reference}</dd>
              <dt class="opacity-70">Last synced</dt>
              <dd class="text-xs" data-testid="sub-stored-synced">{time(@selected.synced_at)}</dd>
            </dl>
          </div>

          <div class="rounded-box bg-base-100 p-4" data-testid="subscription-live">
            <h4 class="font-medium">Live from Stripe</h4>
            <.hint>MishkaPay.fetch_subscription/3 and MishkaPay.list_invoices/3</.hint>
            <.async_result :let={live} assign={@live}>
              <:loading>
                <span class="loading loading-dots loading-sm"></span> Asking Stripe...
              </:loading>
              <:failed :let={{:error, reason}}>
                <span class="text-error text-sm" data-testid="sub-live-error">{reason}</span>
              </:failed>
              <dl class="grid grid-cols-2 gap-y-1 text-sm mt-2">
                <dt class="opacity-70">Status</dt>
                <dd data-testid="sub-live-status">
                  <.sub_status status={live.subscription.status} />
                </dd>
                <dt class="opacity-70">Items</dt>
                <dd class="text-xs" data-testid="sub-live-items">
                  <span :for={item <- live.subscription.items} class="block">
                    {item.quantity} × {item.name} · {Money.to_string!(item.amount)} / {every(item)}
                  </span>
                </dd>
                <dt class="opacity-70">Period</dt>
                <dd class="text-xs">
                  {time(live.subscription.current_period_start)} to {time(
                    live.subscription.current_period_end
                  )}
                </dd>
                <dt :if={active?(live.subscription)} class="opacity-70">Ends then</dt>
                <dd :if={active?(live.subscription)} data-testid="sub-live-cancel">
                  {yes_no(live.subscription.cancel_at_period_end)}
                </dd>
                <dt :if={live.subscription.trial_end} class="opacity-70">Trial ends</dt>
                <dd :if={live.subscription.trial_end} class="text-xs">
                  {time(live.subscription.trial_end)}
                </dd>
                <dt class="opacity-70">Buyer</dt>
                <dd>
                  {live.subscription.customer_name || "–"}
                  <span class="block text-xs opacity-70">{live.subscription.customer_email}</span>
                </dd>
              </dl>
              <div class="mt-3" data-testid="sub-invoices">
                <h5 class="text-sm font-medium">Invoices ({length(live.invoices)})</h5>
                <ul class="text-xs space-y-1 mt-1">
                  <li
                    :for={invoice <- live.invoices}
                    class="flex flex-wrap gap-2"
                    data-testid="sub-invoice"
                  >
                    <code>{invoice.id}</code>
                    <span class="badge badge-xs">{invoice.status}</span>
                    <span
                      :if={invoice.status == :open}
                      class="opacity-60"
                      data-testid="sub-invoice-open-note"
                    >
                      not paid yet: the charge failed or is waiting
                    </span>
                    <span>{money(invoice.amount_paid)} of {money(invoice.amount_due)}</span>
                    <span class="opacity-60">{time(invoice.created_at)}</span>
                    <a :if={invoice.hosted_url} href={invoice.hosted_url} target="_blank" class="link">
                      bill
                    </a>
                    <a :if={invoice.pdf_url} href={invoice.pdf_url} target="_blank" class="link">PDF</a>
                  </li>
                </ul>
              </div>
            </.async_result>
          </div>
        </div>

        <div
          class="rounded-box bg-base-100 p-4 flex flex-wrap gap-2"
          data-testid="subscription-actions"
        >
          <.act
            :if={active?(@selected) and not @selected.cancel_at_period_end}
            id={@selected.id}
            action="cancel_period_end"
            myself={@myself}
            class="btn-warning"
          >
            Cancel at period end
          </.act>
          <.act
            :if={active?(@selected) and @selected.cancel_at_period_end}
            id={@selected.id}
            action="resume"
            myself={@myself}
            class="btn-success"
          >
            Keep it going
          </.act>
          <.act
            :if={active?(@selected)}
            id={@selected.id}
            action="cancel_now"
            myself={@myself}
            class="btn-error"
          >
            Cancel now
          </.act>
          <span
            :if={@selected.quantity}
            class="badge badge-ghost self-center"
            data-testid="sub-quantity"
          >
            quantity {@selected.quantity}
          </span>
          <span
            :if={@selected.pause_behavior}
            class="badge badge-warning self-center"
            data-testid="sub-paused"
          >
            collection paused ({@selected.pause_behavior}{if @selected.resumes_at,
              do: ", resumes #{time(@selected.resumes_at)}"})
          </span>
          <.act id={@selected.id} action="sync" myself={@myself} class="">
            <.icon name="hero-arrow-path" class="size-4" /> Sync from Stripe
          </.act>
          <p
            :if={not active?(@selected)}
            class="text-sm opacity-70 self-center"
            data-testid="subscription-ended"
          >
            This subscription has ended: nothing to cancel or keep.
          </p>
        </div>

        <.change_panel
          :if={active?(@selected)}
          selected={@selected}
          plans={@plans}
          preview={@preview}
          myself={@myself}
        />
      </div>
    </div>
    """
  end

  attr :selected, :map, required: true
  attr :plans, :list, required: true
  attr :preview, :any, required: true
  attr :myself, :any, required: true

  defp change_panel(assigns) do
    ~H"""
    <div class="grid gap-4 md:grid-cols-2">
      <form
        phx-submit="preview_change"
        phx-target={@myself}
        class="rounded-box bg-base-100 p-4"
        data-testid="change-form"
      >
        <h4 class="font-medium">Change plan or quantity</h4>
        <.hint>MishkaPay.preview_subscription_change/1, then :change</.hint>
        <div class="grid gap-2 sm:grid-cols-2 mt-2">
          <label class="fieldset">
            <span class="fieldset-legend">Plan</span>
            <select name="price_id" class="select select-sm" data-testid="change-plan">
              <option value="">Keep the plan</option>
              <option :for={plan <- @plans} value={plan.stripe_price_id}>
                {plan.name} (${plan.price})
              </option>
            </select>
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Quantity (seats)</span>
            <input
              name="quantity"
              type="number"
              min="1"
              placeholder={"now #{@selected.quantity || 1}"}
              class="input input-sm"
              data-testid="change-quantity"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Bill the difference</span>
            <select name="proration" class="select select-sm" data-testid="change-proration">
              <option value="">Stripe's default (on the next invoice)</option>
              <option value="always_invoice">Now, on its own invoice</option>
              <option value="create_prorations">On the next invoice</option>
              <option value="none">Not at all</option>
            </select>
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Billing period</span>
            <select name="billing_cycle_anchor" class="select select-sm" data-testid="change-anchor">
              <option value="">Keep the dates</option>
              <option value="now">Start a new period now</option>
            </select>
          </label>
          <label class="fieldset sm:col-span-2">
            <span class="fieldset-legend">If charging the difference fails</span>
            <select
              name="payment_behavior"
              class="select select-sm"
              data-testid="change-payment-behavior"
            >
              <option value="">Stripe's default</option>
              <option value="error_if_incomplete">Refuse the change</option>
              <option value="allow_incomplete">Change it, and leave the invoice open</option>
              <option value="pending_if_incomplete">Change it only once paid</option>
            </select>
          </label>
        </div>
        <button
          class="btn btn-sm mt-3"
          phx-disable-with="Asking Stripe..."
          data-testid="change-preview"
        >
          Preview the bill
        </button>
      </form>

      <div class="rounded-box bg-base-100 p-4 space-y-3">
        <div :if={@preview} data-testid="change-preview-result">
          <h4 class="font-medium">What it bills</h4>
          <ul class="text-sm space-y-1 mt-2">
            <li :for={line <- @preview.lines} class="flex gap-2" data-testid="change-line">
              <span class="flex-1">{line.description}</span>
              <span class={[
                "font-mono",
                line.amount && Decimal.negative?(line.amount.amount) && "text-success"
              ]}>
                {money(line.amount)}
              </span>
            </li>
          </ul>
          <p
            :if={@preview.amount_tax && !Money.zero?(@preview.amount_tax)}
            class="text-sm flex gap-2"
            data-testid="change-tax"
          >
            <span class="flex-1 opacity-70">Tax</span>
            <span class="font-mono">{money(@preview.amount_tax)}</span>
          </p>
          <p class="font-medium mt-2" data-testid="change-due">Due: {money(@preview.amount_due)}</p>
          <div class="flex gap-2 mt-2">
            <button
              class="btn btn-sm btn-primary"
              phx-click="apply_change"
              phx-target={@myself}
              phx-disable-with="Asking Stripe..."
              data-testid="change-apply"
            >
              Apply this change
            </button>
            <button
              class="btn btn-sm btn-ghost"
              phx-click="cancel_change"
              phx-target={@myself}
              data-testid="change-cancel"
            >
              Not now
            </button>
          </div>
        </div>

        <form
          phx-submit="pause"
          phx-target={@myself}
          data-testid="pause-form"
          class={[@preview && "border-t border-base-300 pt-3"]}
        >
          <h4 class="font-medium">Pause collecting payments</h4>
          <.hint>:pause and :resume_collection</.hint>
          <input type="hidden" name="subscription" value={@selected.id} />
          <div class="flex flex-wrap items-end gap-2">
            <label class="fieldset">
              <span class="fieldset-legend">Invoices meanwhile</span>
              <select name="behavior" class="select select-sm" data-testid="pause-behavior">
                <option value="void">Void them</option>
                <option value="keep_as_draft">Keep as drafts</option>
                <option value="mark_uncollectible">Mark uncollectible</option>
              </select>
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Resumes by itself on</span>
              <input
                name="resumes_at"
                type="date"
                class="input input-sm"
                data-testid="pause-resumes-at"
              />
            </label>
            <button
              class="btn btn-sm btn-warning"
              phx-disable-with="Asking Stripe..."
              data-testid="pause-submit"
            >
              Pause
            </button>
            <button
              :if={@selected.pause_behavior}
              type="button"
              class="btn btn-sm btn-success"
              phx-click="resume_collection"
              phx-value-id={@selected.id}
              phx-target={@myself}
              data-testid="resume-collection"
            >
              Collect again
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :action, :string, required: true
  attr :myself, :any, required: true
  attr :class, :string, required: true
  slot :inner_block, required: true

  defp act(assigns) do
    ~H"""
    <button
      class={["btn btn-sm", @class]}
      phx-click="act"
      phx-value-id={@id}
      phx-value-action={@action}
      phx-target={@myself}
      phx-disable-with="Asking Stripe..."
      data-testid={"subscription-#{@action}"}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :status, :atom, required: true

  defp sub_status(assigns) do
    ~H"""
    <span class={["badge badge-sm", status_class(@status)]} data-testid="status-badge">{@status}</span>
    """
  end

  defp run_action(socket, id, action, args, message) do
    row = Ash.get!(Subscription, id, authorize?: false)

    case row |> Ash.Changeset.for_update(action, args) |> Ash.update(authorize?: false) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> stream_insert(:subscriptions, updated, at: 0)
         |> select(updated.id)
         |> say(:info, message)}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  # Only what the form sets; the rest stays the provider's default.
  defp change_attrs(params, row) do
    %{
      provider: row.provider,
      tenant: row.tenant,
      subscription_id: row.provider_id,
      price_id: blank_nil(params["price_id"]),
      quantity: integer(params["quantity"]),
      proration: blank_nil(params["proration"]),
      billing_cycle_anchor: blank_nil(params["billing_cycle_anchor"]),
      payment_behavior: blank_nil(params["payment_behavior"])
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> dated()
  end

  # A change that prorates is dated once, here: the preview and the change count from the same
  # second, so the change bills what the preview showed.
  defp dated(change) do
    case MishkaPay.SubscriptionChange.prorates?(change) do
      true -> Map.put(change, :proration_date, DateTime.truncate(DateTime.utc_now(), :second))
      false -> change
    end
  end

  defp date(value) do
    with text when is_binary(text) and text != "" <- value,
         {:ok, day} <- Date.from_iso8601(text),
         {:ok, at} <- DateTime.new(day, ~T[12:00:00], "Etc/UTC") do
      at
    else
      _no_date -> nil
    end
  end

  defp integer(value) do
    case Integer.parse(String.trim(value || "")) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp blank_nil(value) do
    case String.trim(value || "") do
      "" -> nil
      text -> text
    end
  end

  defp perform(row, "cancel_period_end"), do: run(row, :cancel, %{at: :period_end})
  defp perform(row, "cancel_now"), do: run(row, :cancel, %{at: :now})
  defp perform(row, "resume"), do: run(row, :resume, %{})
  defp perform(row, "sync"), do: sync(row.provider_id, row.tenant)

  defp run(row, action, args),
    do: row |> Ash.Changeset.for_update(action, args) |> Ash.update(authorize?: false)

  defp done("cancel_period_end"),
    do: "It ends when the period paid for is over. You can still keep it going."

  defp done("cancel_now"), do: "Canceled now."
  defp done("resume"), do: "It goes on: the cancel is taken back."
  defp done("sync"), do: "Subscription read from Stripe and saved."

  defp sync(subscription_id, tenant) do
    Ash.create(
      Subscription,
      %{provider: "stripe", subscription_id: subscription_id, tenant: tenant},
      action: :sync,
      authorize?: false
    )
  end

  # The row now, and the subscription and its invoices from Stripe in the background.
  defp select(socket, id) do
    row = Ash.get!(Subscription, id, authorize?: false)

    socket
    |> assign(selected: row)
    |> assign_async(
      :live,
      fn ->
        with {:ok, subscription} <-
               MishkaPay.fetch_subscription(row.provider, row.provider_id, row.tenant),
             {:ok, %MishkaPay.Page{items: invoices}} <-
               MishkaPay.list_invoices(row.provider, row.tenant,
                 subscription_id: row.provider_id,
                 limit: 24
               ) do
          {:ok, %{live: %{subscription: subscription, invoices: invoices}}}
        else
          {:error, error} -> {:error, MishkaPay.Ash.message(error)}
        end
      end,
      reset: true
    )
  end

  defp reselect(%{assigns: %{selected: %{id: id}}} = socket, %{id: id}), do: select(socket, id)
  defp reselect(socket, _other), do: socket

  # The shop's plans published to Stripe's catalog: a change swaps to one of their prices.
  defp plans, do: Enum.filter(Shop.Catalog.all(), &(&1.interval && &1.stripe_price_id))

  defp newest do
    Subscription
    |> Ash.Query.sort(provider_created_at: :desc_nils_last, inserted_at: :desc)
    |> Ash.Query.limit(50)
    |> Ash.read!(authorize?: false)
  end

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end

  defp subscription_id(value) do
    case String.trim(value || "") do
      "" -> {:error, "Type a subscription id first, it starts with sub_."}
      "pi_" <> _ -> {:error, ~s|That is a payment id (pi_). Use "Read payment" above.|}
      id -> {:ok, id}
    end
  end

  attr :sub, :map, required: true

  defp period(assigns) do
    ~H"""
    <span :if={active?(@sub)}>{time(@sub.current_period_end)}</span>
    <span :if={!active?(@sub)}>Ended {time(ended_at(@sub))}</span>
    """
  end

  defp ended_at(sub), do: sub.canceled_at || sub.current_period_end

  defp active?(%{status: status}), do: status not in [:canceled, :incomplete_expired]

  defp price(%{amount: nil}), do: "–"

  defp price(sub),
    do: "#{sub.currency |> Money.new(sub.amount) |> Money.to_string!()} / #{every(sub)}"

  defp every(%{interval: nil}), do: "once"

  defp every(%{interval: interval, interval_count: count}) when count in [nil, 1],
    do: "#{interval}"

  defp every(%{interval: interval, interval_count: count}), do: "#{count} #{interval}s"

  defp money(nil), do: "–"
  defp money(money), do: Money.to_string!(money)

  defp yes_no(true), do: "yes"
  defp yes_no(_no), do: "no"

  defp time(nil), do: "–"
  defp time(%DateTime{} = time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M")

  defp status_class(:active), do: "badge-success"
  defp status_class(:trialing), do: "badge-info"
  defp status_class(status) when status in [:past_due, :unpaid, :incomplete], do: "badge-warning"
  defp status_class(_ended), do: "badge-error"
end

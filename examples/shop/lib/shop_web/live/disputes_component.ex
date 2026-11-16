defmodule ShopWeb.DisputesComponent do
  @moduledoc """
  The disputes part of the demo shop, on Mishka Pay's `:dispute` kind (`MishkaPay.Ash.Resource`):
  every chargeback the shop keeps, live (`charge.dispute.*` webhooks through the inbox, or "Read
  disputes from Stripe" with `MishkaPay.list_disputes/3`), and one at a time: its amount, status,
  reason and due date, an evidence form (`:submit_evidence`, `MishkaPay.update_dispute/1`) and
  accepting the loss (`:accept`, `MishkaPay.accept_dispute/3`). Pay with the dispute test card to
  make one. The page sends it each changed dispute (`changed`).
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  alias Shop.Pay.Dispute

  @impl true
  def mount(socket), do: {:ok, assign(socket, selected: nil, loaded?: false)}

  @impl true
  def update(%{changed: record}, socket) do
    {:ok, socket |> stream_insert(:disputes, record, at: 0) |> reselect(record)}
  end

  def update(assigns, socket) do
    socket = assign(socket, tenant: assigns.tenant)

    case socket.assigns.loaded? do
      true -> {:ok, socket}
      false -> {:ok, socket |> assign(loaded?: true) |> stream(:disputes, newest())}
    end
  end

  @impl true
  def handle_event("read", _params, socket) do
    case MishkaPay.list_disputes("stripe", socket.assigns.tenant, limit: 10) do
      {:ok, %MishkaPay.Page{items: disputes}} ->
        rows =
          for dispute <- disputes,
              {:ok, row} <- [sync(dispute.id, socket.assigns.tenant)],
              do: row

        {:noreply,
         socket
         |> stream(:disputes, rows)
         |> say(:info, "#{length(rows)} disputes read from Stripe and saved.")}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("select", %{"id" => id}, socket),
    do: {:noreply, assign(socket, selected: Ash.get!(Dispute, id, authorize?: false))}

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, selected: nil)}

  def handle_event("evidence", %{"dispute" => id} = params, socket) do
    evidence =
      for field <- ~w(product_description customer_email_address uncategorized_text),
          value = String.trim(params[field] || ""),
          value != "",
          into: %{},
          do: {field, value}

    args = %{evidence: evidence, submit: params["submit"] == "true"}

    message =
      if args.submit, do: "Evidence sent to the bank.", else: "Evidence saved on Stripe."

    run(socket, id, :submit_evidence, args, message)
  end

  def handle_event("accept", %{"id" => id}, socket),
    do: run(socket, id, :accept, %{}, "Dispute accepted: the payment stays with the buyer.")

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="disputes" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <.section_title icon="hero-shield-exclamation" title="Disputes" />
        <button
          class="btn btn-sm"
          phx-click="read"
          phx-target={@myself}
          phx-disable-with="Asking Stripe..."
          data-testid="disputes-read"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Read disputes from Stripe
        </button>
      </div>
      <p class="text-sm opacity-70">
        A buyer's bank asking for a payment back. Pay with the dispute test card
        (4000 0000 0000 0259) to make one: it comes in by webhook, or press "Read disputes".
      </p>

      <div class="overflow-x-auto rounded-box border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>Dispute</th>
              <th>Amount</th>
              <th>Reason</th>
              <th>Status</th>
              <th>Answer by</th>
            </tr>
          </thead>
          <tbody id="disputes" phx-update="stream" data-testid="dispute-rows">
            <tr id="disputes-empty" class="only:table-row hidden">
              <td colspan="5" class="text-center opacity-70">No disputes. Good.</td>
            </tr>
            <tr
              :for={{dom_id, dispute} <- @streams.disputes}
              id={dom_id}
              class="hover:bg-base-200 cursor-pointer"
              phx-click="select"
              phx-value-id={dispute.id}
              phx-target={@myself}
              data-testid="dispute-row"
              data-dispute-id={dispute.provider_id}
              data-status={dispute.status}
            >
              <td>
                <div class="font-mono text-xs">{dispute.provider_id}</div>
                <div class="text-xs opacity-60 font-mono">{dispute.payment_id}</div>
              </td>
              <td>{money(dispute)}</td>
              <td class="text-sm">{dispute.reason}</td>
              <td><.status status={dispute.status} /></td>
              <td class="text-xs">{time(dispute.evidence_due_by)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <.details :if={@selected} dispute={@selected} myself={@myself} />
    </section>
    """
  end

  attr :dispute, :map, required: true
  attr :myself, :any, required: true

  defp details(assigns) do
    ~H"""
    <div
      class="card bg-base-200 border border-primary/40"
      data-testid="dispute-details"
      data-dispute-id={@dispute.provider_id}
    >
      <div class="card-body gap-4">
        <div class="flex flex-wrap items-center gap-3">
          <h3 class="card-title flex-1">
            {money(@dispute)} · {@dispute.reason} <.status status={@dispute.status} />
          </h3>
          <a
            href={"https://dashboard.stripe.com/test/disputes/#{@dispute.provider_id}"}
            target="_blank"
            class="btn btn-ghost btn-sm"
            data-testid="dispute-stripe-link"
          >
            Stripe <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </a>
          <button
            class="btn btn-ghost btn-sm"
            phx-click="close"
            phx-target={@myself}
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <dl class="grid grid-cols-2 gap-y-1 text-sm max-w-xl">
          <dt class="opacity-70">Payment</dt>
          <dd class="font-mono text-xs">{@dispute.payment_id}</dd>
          <dt class="opacity-70">Answer by</dt>
          <dd>{time(@dispute.evidence_due_by)}</dd>
          <dt class="opacity-70">Evidence</dt>
          <dd data-testid="dispute-evidence-state">
            {if @dispute.has_evidence, do: "given", else: "none yet"} · sent {@dispute.submission_count} times
          </dd>
          <dt class="opacity-70">Can still refund instead</dt>
          <dd>{if @dispute.refundable, do: "yes", else: "no"}</dd>
        </dl>

        <form
          :if={open?(@dispute)}
          phx-submit="evidence"
          phx-target={@myself}
          class="rounded-box bg-base-100 p-4"
          data-testid="dispute-evidence-form"
        >
          <h4 class="font-medium">Answer with evidence</h4>
          <.hint>Shop.Pay.Dispute :submit_evidence, MishkaPay.update_dispute/1</.hint>
          <input type="hidden" name="dispute" value={@dispute.id} />
          <div class="grid gap-2 sm:grid-cols-2">
            <label class="fieldset">
              <span class="fieldset-legend">What was sold</span>
              <input name="product_description" class="input input-sm" data-testid="evidence-product" />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Buyer's email</span>
              <input
                name="customer_email_address"
                type="email"
                class="input input-sm"
                data-testid="evidence-email"
              />
            </label>
            <label class="fieldset sm:col-span-2">
              <span class="fieldset-legend">
                Anything else (in test mode "winning_evidence" wins, "losing_evidence" loses)
              </span>
              <textarea
                name="uncategorized_text"
                class="textarea textarea-sm"
                data-testid="evidence-text"
              ></textarea>
            </label>
          </div>
          <label class="label gap-2 text-sm mt-2">
            <input
              type="checkbox"
              name="submit"
              value="true"
              class="checkbox checkbox-sm"
              data-testid="evidence-submit-now"
            /> Send to the bank now (otherwise kept to add more)
          </label>
          <div class="flex gap-2 mt-2">
            <button
              class="btn btn-sm btn-primary"
              phx-disable-with="Asking Stripe..."
              data-testid="evidence-save"
            >
              Save evidence
            </button>
            <button
              type="button"
              class="btn btn-sm btn-error btn-outline"
              phx-click="accept"
              phx-value-id={@dispute.id}
              phx-target={@myself}
              data-confirm="Accept this dispute? The buyer keeps the money; this cannot be undone."
              data-testid="dispute-accept"
            >
              Accept the loss
            </button>
          </div>
        </form>
        <p :if={!open?(@dispute)} class="text-sm opacity-70" data-testid="dispute-closed">
          This dispute is {@dispute.status}: nothing more to answer.
        </p>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp status(assigns) do
    ~H"""
    <span class={["badge badge-sm", status_class(@status)]} data-testid="dispute-status">{@status}</span>
    """
  end

  defp run(socket, id, action, args, message) do
    row = Ash.get!(Dispute, id, authorize?: false)

    case row |> Ash.Changeset.for_update(action, args) |> Ash.update(authorize?: false) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> stream_insert(:disputes, updated, at: 0)
         |> assign(selected: updated)
         |> say(:info, message)}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  defp sync(dispute_id, tenant) do
    Ash.create(Dispute, %{provider: "stripe", dispute_id: dispute_id, tenant: tenant},
      action: :sync,
      authorize?: false
    )
  end

  defp reselect(%{assigns: %{selected: %{id: id}}} = socket, %{id: id} = record),
    do: assign(socket, selected: record)

  defp reselect(socket, _other), do: socket

  defp newest do
    Dispute
    |> Ash.Query.sort(provider_created_at: :desc_nils_last, inserted_at: :desc)
    |> Ash.Query.limit(50)
    |> Ash.read!(authorize?: false)
  end

  defp open?(%{status: status}),
    do: status in [:needs_response, :warning_needs_response, :under_review, :warning_under_review]

  defp money(%{amount: nil}), do: "–"

  defp money(%{amount: amount, currency: currency}),
    do: currency |> Money.new(amount) |> Money.to_string!()

  defp time(nil), do: "–"
  defp time(%DateTime{} = time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M")

  defp status_class(status) when status in [:won, :warning_closed, :prevented],
    do: "badge-success"

  defp status_class(:lost), do: "badge-error"
  defp status_class(_open), do: "badge-warning"

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end
end

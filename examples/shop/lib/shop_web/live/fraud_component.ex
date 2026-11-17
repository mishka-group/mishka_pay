defmodule ShopWeb.FraudComponent do
  @moduledoc """
  Fraud on Stripe Radar, in the demo shop: the early fraud warnings card issuers sent
  (`MishkaPay.list_fraud_warnings/3`), each with its payment and whether a full refund can still
  head off a dispute, and the payments Radar's rules hold for review
  (`MishkaPay.list_fraud_reviews/3`), each let through with Approve
  (`MishkaPay.approve_fraud_review/3`).

  Nothing is read when the page opens: "Show fraud" reads both lists in the background
  (`start_async`), and "Read again" reads them once more.
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open?: false,
       reading?: false,
       warnings: [],
       reviews: [],
       notice: nil,
       error: nil
     )}
  end

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, tenant: assigns.tenant)}

  @impl true
  def handle_event("show", _params, socket),
    do: {:noreply, socket |> assign(open?: true) |> read()}

  def handle_event("read", _params, socket), do: {:noreply, read(socket)}

  def handle_event("approve", %{"id" => id}, socket) do
    case MishkaPay.approve_fraud_review("stripe", id, socket.assigns.tenant) do
      {:ok, review} ->
        {:noreply,
         socket
         |> update(:reviews, fn reviews -> Enum.reject(reviews, &(&1.id == review.id)) end)
         |> assign(notice: "Review #{review.id} approved: its payment goes on.", error: nil)}

      {:error, error} ->
        {:noreply, assign(socket, error: MishkaPay.Ash.message(error), notice: nil)}
    end
  end

  @impl true
  def handle_async(:fraud, {:ok, {:ok, warnings, reviews}}, socket),
    do: {:noreply, assign(socket, reading?: false, warnings: warnings, reviews: reviews)}

  def handle_async(:fraud, {:ok, {:error, error}}, socket),
    do:
      {:noreply,
       assign(socket, reading?: false, error: MishkaPay.Ash.message(error), notice: nil)}

  def handle_async(:fraud, {:exit, reason}, socket),
    do: {:noreply, assign(socket, reading?: false, error: inspect(reason), notice: nil)}

  defp read(socket) do
    tenant = socket.assigns.tenant

    socket
    |> assign(reading?: true, error: nil)
    |> start_async(:fraud, fn ->
      with {:ok, %MishkaPay.Page{items: warnings}} <-
             MishkaPay.list_fraud_warnings("stripe", tenant, limit: 20),
           {:ok, %MishkaPay.Page{items: reviews}} <-
             MishkaPay.list_fraud_reviews("stripe", tenant, limit: 20) do
        {:ok, warnings, reviews}
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="fraud" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <.section_title icon="hero-shield-exclamation" title="Fraud" />
        <button
          :if={!@open?}
          class="btn btn-sm"
          phx-click="show"
          phx-target={@myself}
          data-testid="fraud-show"
        >
          Show fraud
        </button>
        <button
          :if={@open?}
          class="btn btn-sm btn-ghost"
          phx-click="read"
          phx-target={@myself}
          disabled={@reading?}
          data-testid="fraud-read"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Read again
        </button>
      </div>
      <p class="text-sm opacity-70">
        Card issuers' early warnings of fraud, and the payments Radar's rules hold for you to look at.
      </p>
      <.hint>
        MishkaPay.list_fraud_warnings/3, list_fraud_reviews/3, approve_fraud_review/3
      </.hint>

      <div :if={@notice} role="status" class="alert alert-success py-2" data-testid="fraud-notice">
        {@notice}
      </div>
      <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="fraud-error">
        {@error}
      </div>
      <span
        :if={@reading?}
        class="loading loading-spinner loading-sm"
        data-testid="fraud-reading"
      ></span>

      <div :if={@open? and !@reading?} class="grid gap-4 lg:grid-cols-2">
        <div class="overflow-x-auto rounded-box border border-base-300">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Early fraud warning</th>
                <th>Payment</th>
                <th>Kind</th>
                <th>Can refund first</th>
              </tr>
            </thead>
            <tbody data-testid="fraud-warning-rows">
              <tr :if={@warnings == []}>
                <td colspan="4" class="text-center opacity-70" data-testid="fraud-warnings-empty">
                  No warnings.
                </td>
              </tr>
              <tr
                :for={warning <- @warnings}
                data-testid="fraud-warning-row"
                data-warning-id={warning.id}
              >
                <td class="font-mono text-xs">{warning.id}</td>
                <td class="font-mono text-xs">{warning.payment_id || warning.charge_id}</td>
                <td>{warning.fraud_type}</td>
                <td>
                  <span
                    class={[
                      "badge badge-sm",
                      (warning.actionable && "badge-warning") || "badge-ghost"
                    ]}
                    data-testid="fraud-warning-actionable"
                  >
                    {if warning.actionable, do: "yes", else: "no"}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="overflow-x-auto rounded-box border border-base-300">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Open review</th>
                <th>Payment</th>
                <th>Why</th>
                <th></th>
              </tr>
            </thead>
            <tbody data-testid="fraud-review-rows">
              <tr :if={@reviews == []}>
                <td colspan="4" class="text-center opacity-70" data-testid="fraud-reviews-empty">
                  No payments wait for review.
                </td>
              </tr>
              <tr :for={review <- @reviews} data-testid="fraud-review-row" data-review-id={review.id}>
                <td class="font-mono text-xs">{review.id}</td>
                <td class="font-mono text-xs">{review.payment_id || review.charge_id}</td>
                <td>{review.reason}</td>
                <td>
                  <button
                    class="btn btn-xs btn-success btn-outline"
                    phx-click="approve"
                    phx-value-id={review.id}
                    phx-target={@myself}
                    phx-disable-with="Asking Stripe..."
                    data-confirm="Approve this payment? It goes on as it is."
                    data-testid="fraud-review-approve"
                  >
                    Approve
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end
end

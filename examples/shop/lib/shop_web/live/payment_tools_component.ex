defmodule ShopWeb.PaymentToolsComponent do
  @moduledoc """
  Refunds and held money, per payment row of the demo shop: "Refunds" runs `Shop.Pay.Payment`'s
  generic `:refunds` action (every refund made on the payment, read from Stripe); a payment held
  by a pay-later checkout (`capture: :manual`, status `:authorized`) is taken, all or part, with
  `MishkaPay.capture_payment/4`, or let go with `MishkaPay.cancel_payment/3`, then synced. A box
  reads one refund by its id (`MishkaPay.fetch_refund/3`). The page sends it each changed payment
  (`changed`).
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  alias Shop.Pay.Payment

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(loaded?: false, refunds: nil, refund: nil, refund_error: nil)
     |> stream_configure(:payments, dom_id: &"payment-tools-#{&1.id}")}
  end

  @impl true
  def update(%{changed: record}, socket),
    do: {:ok, stream_insert(socket, :payments, record, at: 0)}

  def update(assigns, socket) do
    socket = assign(socket, tenant: assigns.tenant)

    case socket.assigns.loaded? do
      true -> {:ok, socket}
      false -> {:ok, socket |> assign(loaded?: true) |> stream(:payments, newest())}
    end
  end

  @impl true
  def handle_event("refunds", %{"id" => id}, socket) do
    row = Ash.get!(Payment, id, authorize?: false)

    Payment
    |> Ash.ActionInput.for_action(:refunds, %{id: id})
    |> Ash.run_action(authorize?: false)
    |> case do
      {:ok, refunds} ->
        {:noreply, assign(socket, refunds: %{payment: row, items: refunds})}

      {:error, error} ->
        {:noreply, socket |> assign(refunds: nil) |> say(:error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("close_refunds", _params, socket), do: {:noreply, assign(socket, refunds: nil)}

  def handle_event("capture", %{"payment" => id} = params, socket) do
    row = Ash.get!(Payment, id, authorize?: false)
    opts = capture_opts(params["amount"], row.currency)

    held(socket, row, "Captured: the money is taken.", fn ->
      MishkaPay.capture_payment(row.provider, row.provider_id, row.tenant, opts)
    end)
  end

  def handle_event("cancel_hold", %{"id" => id}, socket) do
    row = Ash.get!(Payment, id, authorize?: false)

    held(socket, row, "Let go: the buyer's card is no longer held.", fn ->
      MishkaPay.cancel_payment(row.provider, row.provider_id, row.tenant)
    end)
  end

  def handle_event("read_refund", %{"refund_id" => value}, socket) do
    with {:ok, refund_id} <- refund_id(value),
         {:ok, refund} <- MishkaPay.fetch_refund("stripe", refund_id, socket.assigns.tenant) do
      {:noreply, assign(socket, refund: refund, refund_error: nil)}
    else
      {:error, error} ->
        message = if is_binary(error), do: error, else: MishkaPay.Ash.message(error)
        {:noreply, socket |> assign(refund: nil, refund_error: message) |> say(:error, message)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="payment-tools" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <.section_title icon="hero-receipt-refund" title="Refunds and held payments" />
        <form
          phx-submit="read_refund"
          phx-target={@myself}
          class="join"
          data-testid="read-refund-form"
        >
          <input
            name="refund_id"
            placeholder="re_... from the sandbox"
            class="input input-sm join-item"
            data-testid="read-refund-input"
          />
          <button class="btn btn-sm join-item" data-testid="read-refund-submit">Read refund</button>
        </form>
        <p :if={@refund_error} class="alert alert-error text-sm" data-testid="read-refund-error">
          {@refund_error}
        </p>
      </div>
      <p class="text-sm opacity-70">
        Each payment's refunds as Stripe lists them. A payment bought with "Pay later" (Checkout
        options below) waits as authorized: take all of it, part of it, or let it go.
      </p>

      <dl
        :if={@refund}
        class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm rounded-box bg-base-200 p-4 max-w-xl"
        data-testid="refund-card"
      >
        <dt class="opacity-70">Refund</dt>
        <dd class="font-mono text-xs" data-testid="refund-card-id">{@refund.id}</dd>
        <dt class="opacity-70">Status</dt>
        <dd data-testid="refund-card-status"><span class="badge badge-sm">{@refund.status}</span></dd>
        <dt class="opacity-70">Amount</dt>
        <dd data-testid="refund-card-amount">{money(@refund.amount)}</dd>
        <dt class="opacity-70">Payment</dt>
        <dd class="font-mono text-xs">{@refund.payment_id}</dd>
        <dt class="opacity-70">Reason</dt>
        <dd>{@refund.reason || "–"}</dd>
        <dt class="opacity-70">Made</dt>
        <dd class="text-xs">{time(@refund.created_at)}</dd>
      </dl>

      <div class="overflow-x-auto rounded-box border border-base-300">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Payment</th>
              <th>Amount</th>
              <th>Status</th>
              <th>Do</th>
            </tr>
          </thead>
          <tbody id="payment-tools-rows" phx-update="stream" data-testid="payment-tools-rows">
            <tr id="payment-tools-empty" class="only:table-row hidden">
              <td colspan="4" class="text-center opacity-70">No payments yet.</td>
            </tr>
            <tr
              :for={{dom_id, payment} <- @streams.payments}
              id={dom_id}
              data-testid="payment-tools-row"
              data-payment-id={payment.provider_id}
              data-status={payment.status}
            >
              <td class="font-mono text-xs">{payment.provider_id}</td>
              <td class="text-sm">{amount(payment)}</td>
              <td>
                <span class="badge badge-sm" data-testid="payment-tools-status">{payment.status}</span>
              </td>
              <td class="flex flex-wrap items-center gap-2">
                <button
                  class="btn btn-xs"
                  phx-click="refunds"
                  phx-value-id={payment.id}
                  phx-target={@myself}
                  phx-disable-with="Asking Stripe..."
                  data-testid="payment-refunds"
                >
                  Refunds
                </button>
                <form
                  :if={payment.status == :authorized}
                  phx-submit="capture"
                  phx-target={@myself}
                  class="join"
                  data-testid="capture-form"
                >
                  <input type="hidden" name="payment" value={payment.id} />
                  <input
                    name="amount"
                    placeholder={"all, or less (#{payment.currency})"}
                    class="input input-xs join-item w-36"
                    data-testid="capture-amount"
                  />
                  <button
                    class="btn btn-xs btn-success join-item"
                    phx-disable-with="Asking Stripe..."
                    data-testid="capture-submit"
                  >
                    Capture
                  </button>
                </form>
                <button
                  :if={payment.status == :authorized}
                  class="btn btn-xs btn-warning"
                  phx-click="cancel_hold"
                  phx-value-id={payment.id}
                  phx-target={@myself}
                  phx-disable-with="Asking Stripe..."
                  data-confirm="Let the held money go back to the buyer? This cannot be undone."
                  data-testid="capture-cancel"
                >
                  Cancel
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div
        :if={@refunds}
        class="rounded-box bg-base-200 p-4"
        data-testid="refund-list"
        data-payment-id={@refunds.payment.provider_id}
      >
        <div class="flex items-center gap-2">
          <h3 class="font-medium flex-1">
            Refunds of <code class="text-sm">{@refunds.payment.provider_id}</code>
          </h3>
          <button
            class="btn btn-ghost btn-sm"
            phx-click="close_refunds"
            phx-target={@myself}
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <.hint>Shop.Pay.Payment :refunds (MishkaPay.list_refunds/3)</.hint>
        <p :if={@refunds.items == []} class="text-sm opacity-70" data-testid="refund-list-empty">
          No refunds on this payment.
        </p>
        <ul class="text-sm space-y-1">
          <li
            :for={refund <- @refunds.items}
            class="flex flex-wrap gap-3"
            data-testid="refund-item"
            data-refund-id={refund.id}
          >
            <code class="text-xs">{refund.id}</code>
            <span>{money(refund.amount)}</span>
            <span class="badge badge-sm">{refund.status}</span>
            <span class="opacity-60">{refund.reason}</span>
            <span class="opacity-60 text-xs">{time(refund.created_at)}</span>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  # Capture or let go at Stripe, then keep the row as Stripe has it now.
  defp held(socket, row, message, call) do
    with {:ok, _payment} <- call.(),
         {:ok, synced} <-
           Ash.create(
             Payment,
             %{provider: row.provider, payment_id: row.provider_id, tenant: row.tenant},
             action: :sync,
             authorize?: false
           ) do
      {:noreply, socket |> stream_insert(:payments, synced) |> say(:info, message)}
    else
      {:error, error} -> {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  defp capture_opts(amount, currency) do
    case String.trim(amount || "") do
      "" -> []
      amount -> [amount: %{amount: amount, currency: currency}]
    end
  end

  defp refund_id(value) do
    case String.trim(value || "") do
      "" -> {:error, "Type a refund id first, it starts with re_."}
      "pi_" <> _ -> {:error, ~s|That is a payment id (pi_). Press "Refunds" on its row.|}
      id -> {:ok, id}
    end
  end

  defp newest do
    Payment
    |> Ash.Query.sort(provider_created_at: :desc_nils_last, inserted_at: :desc)
    |> Ash.Query.limit(20)
    |> Ash.read!(authorize?: false)
  end

  # A hold taken in part shows what was taken beside what was asked.
  defp amount(%{amount: amount, amount_captured: captured, currency: currency})
       when not is_nil(captured) do
    case Decimal.equal?(captured, amount) do
      true ->
        money(Money.new(currency, amount))

      false ->
        "#{money(Money.new(currency, captured))} taken of #{money(Money.new(currency, amount))}"
    end
  end

  defp amount(%{amount: amount, currency: currency}), do: money(Money.new(currency, amount))

  defp money(nil), do: "–"
  defp money(money), do: Money.to_string!(money)

  defp time(nil), do: "–"
  defp time(%DateTime{} = time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M")

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end
end

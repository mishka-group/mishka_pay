defmodule ShopWeb.CreditNotesComponent do
  @moduledoc """
  Credit notes on one open or paid bill, in the bills part of the demo shop: take back an amount
  of the bill or one of its lines, see what it credits first (`MishkaPay.preview_credit_note/1`),
  then make it (`MishkaPay.create_credit_note/1`, its reference made at the preview, so a second
  click makes it once). On a paid bill the money goes back to the card, onto the customer's
  balance, or outside Stripe. The bill's notes are listed (`MishkaPay.list_credit_notes/3`) with
  their lines (`MishkaPay.list_credit_note_lines/4`), and a note is voided while its bill is open
  (`MishkaPay.void_credit_note/3`). After a change the bills part reads the bill again.

  Nothing is read until asked: "Credit note" opens the form, "Show notes" reads the list in the
  background.
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [hint: 1]

  @money_to [
    {"out_of_band_amount", "Settled outside Stripe"},
    {"credit_amount", "Onto the customer's balance"},
    {"refund_amount", "Back to the card (a charged bill)"}
  ]

  @impl true
  def mount(socket), do: {:ok, socket |> assign(bill: nil) |> fresh()}

  @impl true
  def update(%{bill: bill} = assigns, socket) do
    socket =
      case socket.assigns.bill do
        %{id: id} when id == bill.id -> socket
        _another -> fresh(socket)
      end

    {:ok, assign(socket, bill: bill, tenant: assigns.tenant, money_to: @money_to)}
  end

  @impl true
  def handle_event("open", _params, socket), do: {:noreply, assign(socket, open?: true)}

  # A changed form no longer matches its preview: it is previewed again before it is made.
  def handle_event("draft", params, socket),
    do: {:noreply, assign(socket, form: params, preview: nil, reference: nil)}

  def handle_event("submit", %{"do" => "preview"} = params, socket) do
    reference = "credit-#{socket.assigns.bill.id}-#{System.unique_integer([:positive])}"
    attrs = attrs(params, socket.assigns)

    case MishkaPay.preview_credit_note(attrs) do
      {:ok, preview} ->
        {:noreply, assign(socket, form: params, preview: preview, reference: reference)}

      {:error, error} ->
        {:noreply, socket |> assign(form: params, preview: nil) |> refused(error)}
    end
  end

  def handle_event("submit", %{"do" => "create"} = params, %{assigns: %{preview: %{}}} = socket) do
    attrs =
      params
      |> attrs(socket.assigns)
      |> Map.put(:reference, socket.assigns.reference)
      |> Map.merge(goes_to(params, socket.assigns))

    case MishkaPay.create_credit_note(attrs) do
      {:ok, note} ->
        send_update(ShopWeb.BillsComponent, id: "bills", reread: note.invoice_id)

        {:noreply,
         socket
         |> assign(preview: nil, reference: nil)
         |> update(:notes, &[note | Enum.reject(&1 || [], fn old -> old.id == note.id end)])
         |> say(:info, "Credit note #{note.number || note.id} made.")}

      {:error, error} ->
        {:noreply, refused(socket, error)}
    end
  end

  def handle_event("submit", _params, socket),
    do: {:noreply, say(socket, :error, "Preview the credit note first.")}

  def handle_event("notes", _params, socket) do
    %{bill: bill, tenant: tenant} = socket.assigns

    {:noreply,
     socket
     |> assign(reading?: true)
     |> start_async(:notes, fn ->
       MishkaPay.list_credit_notes("stripe", tenant, invoice_id: bill.id, limit: 20)
     end)}
  end

  def handle_event("lines", %{"id" => id}, socket) do
    tenant = socket.assigns.tenant

    {:noreply,
     socket
     |> assign(lines: {id, :reading})
     |> start_async(:lines, fn -> MishkaPay.list_credit_note_lines("stripe", id, tenant) end)}
  end

  def handle_event("void", %{"id" => id}, socket) do
    case MishkaPay.void_credit_note("stripe", id, socket.assigns.tenant) do
      {:ok, note} ->
        send_update(ShopWeb.BillsComponent, id: "bills", reread: note.invoice_id)

        {:noreply,
         socket
         |> update(:notes, fn notes -> Enum.map(notes, &if(&1.id == id, do: note, else: &1)) end)
         |> say(:info, "Credit note voided: it credits nothing now.")}

      {:error, error} ->
        {:noreply, refused(socket, error)}
    end
  end

  @impl true
  def handle_async(:notes, {:ok, {:ok, %MishkaPay.Page{items: notes}}}, socket),
    do: {:noreply, assign(socket, notes: notes, reading?: false)}

  def handle_async(:lines, {:ok, {:ok, %MishkaPay.Page{items: lines}}}, socket) do
    {id, _reading} = socket.assigns.lines
    {:noreply, assign(socket, lines: {id, lines})}
  end

  def handle_async(_read, {:ok, {:error, error}}, socket),
    do: {:noreply, socket |> assign(reading?: false, lines: nil) |> refused(error)}

  def handle_async(_read, {:exit, reason}, socket) do
    {:noreply,
     socket |> assign(reading?: false, lines: nil) |> say(:error, "Stripe: #{inspect(reason)}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="border-t border-base-300 pt-3 space-y-3" data-testid="credit-notes">
      <div class="flex flex-wrap items-center gap-2">
        <h4 class="font-medium">Credit notes</h4>
        <button
          :if={!@open?}
          class="btn btn-xs"
          phx-click="open"
          phx-target={@myself}
          data-testid="credit-note-open"
        >
          Credit note
        </button>
        <button
          class="btn btn-xs btn-ghost"
          phx-click="notes"
          phx-target={@myself}
          disabled={@reading?}
          data-testid="credit-note-show"
        >
          {if is_nil(@notes), do: "Show notes", else: "Read notes again"}
        </button>
        <span
          :if={@reading?}
          class="loading loading-dots loading-xs"
          data-testid="credit-notes-reading"
        ></span>
      </div>

      <form
        :if={@open?}
        id="credit-note-form"
        phx-change="draft"
        phx-submit="submit"
        phx-target={@myself}
        class="space-y-2"
        data-testid="credit-note-form"
      >
        <.hint>MishkaPay.preview_credit_note/1, then create_credit_note/1</.hint>
        <div class="grid gap-2 sm:grid-cols-2">
          <label class="fieldset">
            <span class="fieldset-legend">Take back</span>
            <select name="what" class="select select-sm" data-testid="credit-note-what">
              <option value="amount" selected={@form["what"] == "amount"}>
                An amount of the bill
              </option>
              <option
                :for={line <- Enum.filter(@bill.lines, & &1.id)}
                value={line.id}
                selected={@form["what"] == line.id}
              >
                Line: {line.description} ({money(line.amount)})
              </option>
            </select>
          </label>
          <label :if={@form["what"] == "amount"} class="fieldset">
            <span class="fieldset-legend">Amount, {currency(@bill)}</span>
            <input
              name="amount"
              value={@form["amount"]}
              placeholder="10.00"
              class="input input-sm"
              data-testid="credit-note-amount"
            />
          </label>
          <label :if={@form["what"] != "amount"} class="fieldset">
            <span class="fieldset-legend">How many of it</span>
            <input
              name="quantity"
              type="number"
              min="1"
              value={@form["quantity"]}
              class="input input-sm"
              data-testid="credit-note-quantity"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Why</span>
            <select name="reason" class="select select-sm" data-testid="credit-note-reason">
              <option value="">No reason given</option>
              <option
                :for={
                  {value, label} <- [
                    {"order_change", "The order changed"},
                    {"product_unsatisfactory", "Not happy with it"},
                    {"duplicate", "Billed twice"},
                    {"fraudulent", "Fraud"}
                  ]
                }
                value={value}
                selected={@form["reason"] == value}
              >
                {label}
              </option>
            </select>
          </label>
          <label :if={@bill.status == :paid} class="fieldset">
            <span class="fieldset-legend">The money goes</span>
            <select name="money_to" class="select select-sm" data-testid="credit-note-money-to">
              <option
                :for={{value, label} <- @money_to}
                value={value}
                selected={@form["money_to"] == value}
              >
                {label}
              </option>
            </select>
          </label>
          <label class="fieldset sm:col-span-2">
            <span class="fieldset-legend">Memo on the note</span>
            <input
              name="memo"
              value={@form["memo"]}
              placeholder="Sorry for the trouble."
              class="input input-sm"
              data-testid="credit-note-memo"
            />
          </label>
        </div>
        <p :if={@bill.status == :open} class="text-xs opacity-70">
          The bill is open: the note lowers what is still due.
        </p>

        <div
          :if={@preview}
          class="rounded-box bg-base-100 p-2 text-sm space-y-1"
          data-testid="credit-note-preview-card"
        >
          <p>
            Credits <strong data-testid="credit-note-preview-amount">{money(@preview.amount)}</strong>
            <span :if={@preview.amount_tax} class="opacity-70">
              (tax {money(@preview.amount_tax)})
            </span>
            · <span class="badge badge-xs">{@preview.type}</span>
          </p>
          <ul class="text-xs opacity-80">
            <li :for={line <- @preview.lines} data-testid="credit-note-preview-line">
              {line.name || line.invoice_line_id || "the bill"}: {money(line.amount)}
            </li>
          </ul>
        </div>

        <div class="flex flex-wrap gap-2">
          <button
            name="do"
            value="preview"
            class="btn btn-sm"
            phx-disable-with="Asking Stripe..."
            data-testid="credit-note-preview"
          >
            Preview
          </button>
          <button
            :if={@preview}
            name="do"
            value="create"
            class="btn btn-sm btn-primary"
            phx-disable-with="Asking Stripe..."
            data-confirm={"Make this credit note for #{money(@preview.amount)}? It cannot be deleted, only voided while the bill is open."}
            data-testid="credit-note-create"
          >
            Make it
          </button>
        </div>
      </form>

      <p :if={@notes == []} class="text-sm opacity-70" data-testid="credit-note-empty">
        No credit notes on this bill.
      </p>
      <ul :if={@notes not in [nil, []]} class="text-sm space-y-1">
        <li
          :for={note <- @notes}
          class="rounded-box bg-base-100 p-2 space-y-1"
          data-testid="credit-note-row"
          data-note-id={note.id}
          data-status={note.status}
        >
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-mono text-xs">{note.number || note.id}</span>
            <span>{money(note.amount)}</span>
            <span class="badge badge-xs">{note.status}</span>
            <span class="badge badge-xs badge-ghost">{note.type}</span>
            <span :if={note.reason} class="text-xs opacity-70">{note.reason}</span>
            <a :if={note.pdf_url} href={note.pdf_url} target="_blank" class="link text-xs">PDF</a>
            <button
              class="btn btn-xs btn-ghost"
              phx-click="lines"
              phx-value-id={note.id}
              phx-target={@myself}
              data-testid="credit-note-lines-button"
            >
              Lines
            </button>
            <button
              :if={note.status == :issued and @bill.status == :open}
              class="btn btn-xs btn-error btn-outline"
              phx-click="void"
              phx-value-id={note.id}
              phx-target={@myself}
              phx-disable-with="Asking Stripe..."
              data-confirm="Void this credit note? It stays on record and credits nothing."
              data-testid="credit-note-void"
            >
              Void
            </button>
            <span
              :if={note.status == :issued and @bill.status != :open}
              class="text-xs opacity-60"
              data-testid="credit-note-void-closed"
            >
              Stripe voids a note only while its bill is open.
            </span>
          </div>
          <.note_lines lines={@lines} note_id={note.id} />
        </li>
      </ul>
    </div>
    """
  end

  attr :lines, :any, required: true
  attr :note_id, :string, required: true

  defp note_lines(%{lines: {id, :reading}, note_id: id} = assigns) do
    ~H"""
    <span class="loading loading-dots loading-xs"></span>
    """
  end

  defp note_lines(%{lines: {id, lines}, note_id: id} = assigns) when is_list(lines) do
    assigns = assign(assigns, items: lines)

    ~H"""
    <ul class="text-xs opacity-80 pl-2">
      <li :for={line <- @items} data-testid="credit-note-line" data-type={line.type}>
        {line.name || line.invoice_line_id}: {line.quantity && "#{line.quantity} × "}{money(
          line.amount
        )}
      </li>
    </ul>
    """
  end

  defp note_lines(assigns), do: ~H""

  defp fresh(socket) do
    assign(socket,
      open?: false,
      form: %{"what" => "amount", "quantity" => "1", "money_to" => "out_of_band_amount"},
      preview: nil,
      reference: nil,
      notes: nil,
      lines: nil,
      reading?: false
    )
  end

  # What the form takes back: an amount of the bill, or a quantity of one of its lines.
  defp attrs(params, %{bill: bill, tenant: tenant}) do
    what =
      case params["what"] do
        "amount" ->
          %{amount: %{amount: blank_nil(params["amount"]), currency: currency(bill)}}

        line_id ->
          %{lines: [%{invoice_line_id: line_id, quantity: integer(params["quantity"]) || 1}]}
      end

    %{
      provider: "stripe",
      tenant: tenant,
      invoice_id: bill.id,
      reason: blank_nil(params["reason"]),
      memo: blank_nil(params["memo"])
    }
    |> Map.merge(what)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # On a paid bill all of the note goes where the form says; Stripe needs it to add up.
  defp goes_to(%{"money_to" => to}, %{bill: %{status: :paid}, preview: preview})
       when to in ~w(out_of_band_amount credit_amount refund_amount),
       do: %{String.to_existing_atom(to) => preview.amount}

  defp goes_to(_params, _assigns), do: %{}

  defp currency(%{total: %Money{currency: currency}}), do: Atom.to_string(currency)
  defp currency(_bill), do: "USD"

  defp money(nil), do: "–"
  defp money(money), do: Money.to_string!(money)

  defp integer(value) do
    case Integer.parse(String.trim(value || "")) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp blank_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_nil(_none), do: nil

  defp refused(socket, error), do: say(socket, :error, MishkaPay.Ash.message(error))

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end
end

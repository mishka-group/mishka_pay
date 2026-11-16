defmodule ShopWeb.LookupsComponent do
  @moduledoc """
  Looking things up in the demo shop: Stripe's customers found by email, name or the shop's own
  reference (`MishkaPay.search_customers/3`), a subscription's next bill (`Shop.Pay.Subscription`'s
  generic `:upcoming_invoice` action) and the bill a plan or quantity change would make
  (`:preview_change`), without changing anything.
  """

  use ShopWeb, :live_component

  require Ash.Query

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  alias Shop.Pay.Subscription

  @impl true
  def mount(socket), do: {:ok, assign(socket, found: nil, bill: nil)}

  @impl true
  def update(assigns, socket) do
    {:ok,
     assign(socket,
       tenant: assigns.tenant,
       subscriptions: subscriptions(),
       plans: Enum.filter(Shop.Catalog.all(), &(&1.interval && &1.stripe_price_id))
     )}
  end

  @impl true
  def handle_event("search", params, socket) do
    filters =
      for field <- ~w(email name reference)a,
          value = blank_nil(params[Atom.to_string(field)]),
          do: {field, value}

    with [_ | _] <- filters,
         {:ok, %MishkaPay.Page{items: customers}} <-
           MishkaPay.search_customers("stripe", socket.assigns.tenant, filters ++ [limit: 10]) do
      {:noreply, assign(socket, found: customers)}
    else
      [] ->
        {:noreply, say(socket, :error, "Type an email, a name or a reference to search for.")}

      {:error, error} ->
        {:noreply, socket |> assign(found: nil) |> say(:error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("bill", %{"subscription" => id} = params, socket) do
    {action, args, title} =
      case params["do"] do
        "preview" -> {:preview_change, change_args(params), "If the change is made"}
        _next -> {:upcoming_invoice, %{}, "Next bill"}
      end

    with {:ok, id} <- picked(id),
         {:ok, invoice} <-
           Subscription
           |> Ash.ActionInput.for_action(action, Map.put(args, :id, id))
           |> Ash.run_action(authorize?: false) do
      {:noreply, assign(socket, bill: %{title: title, invoice: invoice})}
    else
      {:error, error} ->
        {:noreply, socket |> assign(bill: nil) |> say(:error, MishkaPay.Ash.message(error))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="lookups" class="space-y-4">
      <.section_title icon="hero-magnifying-glass-circle" title="Find customers, preview bills" />
      <div class="grid gap-4 md:grid-cols-2">
        <div class="rounded-box bg-base-200 p-4 space-y-3">
          <form phx-submit="search" phx-target={@myself} data-testid="customer-search-form">
            <h3 class="font-medium">Search Stripe's customers</h3>
            <.hint>MishkaPay.search_customers/3</.hint>
            <div class="grid gap-2 sm:grid-cols-3">
              <input
                name="email"
                placeholder="email"
                class="input input-sm"
                data-testid="customer-search-email"
              />
              <input
                name="name"
                placeholder="name"
                class="input input-sm"
                data-testid="customer-search-name"
              />
              <input
                name="reference"
                placeholder="the shop's reference"
                class="input input-sm"
                data-testid="customer-search-reference"
              />
            </div>
            <button
              class="btn btn-sm mt-2"
              phx-disable-with="Asking Stripe..."
              data-testid="customer-search-submit"
            >
              Search
            </button>
            <p class="text-xs opacity-60 mt-1">A customer just made may take a minute to show.</p>
          </form>
          <div :if={@found} data-testid="customer-search-results">
            <p :if={@found == []} class="text-sm opacity-70" data-testid="customer-search-empty">
              No customer matches.
            </p>
            <ul class="text-sm space-y-1">
              <li
                :for={customer <- @found}
                class="flex flex-wrap gap-2"
                data-testid="customer-search-result"
                data-customer-id={customer.id}
              >
                <code class="text-xs">{customer.id}</code>
                <span>{customer.name || "–"}</span>
                <span class="opacity-70">{customer.email}</span>
                <span :if={customer.reference} class="opacity-60 text-xs">
                  ref {customer.reference}
                </span>
              </li>
            </ul>
          </div>
        </div>

        <div class="rounded-box bg-base-200 p-4 space-y-3">
          <form phx-submit="bill" phx-target={@myself} data-testid="sub-bill-form">
            <h3 class="font-medium">A subscription's bills, ahead of time</h3>
            <.hint>Shop.Pay.Subscription :upcoming_invoice and :preview_change</.hint>
            <label class="fieldset">
              <span class="fieldset-legend">Subscription</span>
              <select name="subscription" class="select select-sm" data-testid="sub-bill-subscription">
                <option value="">Pick one</option>
                <option :for={sub <- @subscriptions} value={sub.id}>
                  {sub.plan || "Subscription"} · {sub.customer_email || sub.customer_id} · {sub.provider_id}
                </option>
              </select>
            </label>
            <div class="grid gap-2 sm:grid-cols-2">
              <label class="fieldset">
                <span class="fieldset-legend">New plan (preview only)</span>
                <select name="price_id" class="select select-sm" data-testid="sub-bill-plan">
                  <option value="">Keep the plan</option>
                  <option :for={plan <- @plans} value={plan.stripe_price_id}>
                    {plan.name} (${plan.price})
                  </option>
                </select>
              </label>
              <label class="fieldset">
                <span class="fieldset-legend">New quantity (preview only)</span>
                <input
                  name="quantity"
                  type="number"
                  min="1"
                  class="input input-sm"
                  data-testid="sub-bill-quantity"
                />
              </label>
            </div>
            <div class="flex flex-wrap gap-2 mt-2">
              <button
                name="do"
                value="next"
                class="btn btn-sm"
                phx-disable-with="Asking Stripe..."
                data-testid="sub-bill-next"
              >
                Next bill
              </button>
              <button
                name="do"
                value="preview"
                class="btn btn-sm"
                phx-disable-with="Asking Stripe..."
                data-testid="sub-bill-preview"
              >
                Preview the change
              </button>
            </div>
          </form>
          <div :if={@bill} data-testid="sub-bill-result">
            <h4 class="font-medium" data-testid="sub-bill-title">{@bill.title}</h4>
            <ul class="text-sm space-y-1 mt-1">
              <li :for={line <- @bill.invoice.lines} class="flex gap-2" data-testid="sub-bill-line">
                <span class="flex-1">{line.description}</span>
                <span class="font-mono">{money(line.amount)}</span>
              </li>
            </ul>
            <p class="font-medium mt-2" data-testid="sub-bill-due">
              Due: {money(@bill.invoice.amount_due)}
            </p>
            <p :if={@bill.invoice.period_end} class="text-xs opacity-70">
              For the period ending {Calendar.strftime(@bill.invoice.period_end, "%Y-%m-%d")}
            </p>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp change_args(params) do
    %{price_id: blank_nil(params["price_id"]), quantity: integer(params["quantity"])}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp picked(id) do
    case blank_nil(id) do
      nil -> {:error, "Pick a subscription first."}
      id -> {:ok, id}
    end
  end

  defp subscriptions do
    Subscription
    |> Ash.Query.filter(status not in [:canceled, :incomplete_expired])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(30)
    |> Ash.read!(authorize?: false)
  end

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

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end
end

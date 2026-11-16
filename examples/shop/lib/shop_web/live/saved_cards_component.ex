defmodule ShopWeb.SavedCardsComponent do
  @moduledoc """
  A customer's saved cards and portal links in the demo shop. "Save a card" opens a checkout in
  `mode: :setup` (no charge, `currency: "usd"`) for the customer; the cards are listed with
  `MishkaPay.list_payment_methods/3`, one is made the default with
  `MishkaPay.set_default_payment_method/4` and one taken off with
  `MishkaPay.detach_payment_method/3`. A portal link (`MishkaPay.portal_session/1` with `flow:`)
  opens Stripe's portal on one task: cancel or change a subscription, or update the card.
  """

  use ShopWeb, :live_component

  require Ash.Query

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @impl true
  def mount(socket), do: {:ok, assign(socket, customer_id: nil, cards: nil, default: nil)}

  @impl true
  def update(assigns, socket) do
    {:ok,
     assign(socket,
       tenant: assigns.tenant,
       customers: customers(),
       subscriptions: subscriptions()
     )}
  end

  @impl true
  # One form, two buttons: the pressed one comes as `do`.
  def handle_event("cards", %{"do" => "save"} = params, socket) do
    with {:ok, customer_id} <- customer_id(params),
         {:ok, checkout} <- setup_checkout(customer_id, socket.assigns.tenant) do
      {:noreply, redirect(socket, external: checkout.url)}
    else
      {:error, error} -> {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("cards", params, socket) do
    case customer_id(params) do
      {:ok, customer_id} -> {:noreply, list(socket, customer_id)}
      {:error, error} -> {:noreply, say(socket, :error, error)}
    end
  end

  def handle_event("make_default", %{"id" => method_id}, %{assigns: %{customer_id: id}} = socket) do
    case MishkaPay.set_default_payment_method("stripe", id, method_id, socket.assigns.tenant) do
      {:ok, customer} ->
        {:noreply,
         socket
         |> assign(default: customer.default_payment_method)
         |> say(:info, "This card is now the one invoices and subscriptions charge.")}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("detach", %{"id" => method_id}, %{assigns: %{customer_id: id}} = socket) do
    case MishkaPay.detach_payment_method("stripe", method_id, socket.assigns.tenant) do
      {:ok, _method} ->
        {:noreply,
         socket
         |> list(id)
         |> say(:info, "Card taken off the customer. It cannot be charged now.")}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("portal", %{"flow" => flow} = params, socket) do
    attrs =
      %{
        provider: "stripe",
        tenant: socket.assigns.tenant,
        return_url: url(~p"/?portal=back"),
        flow: flow,
        subscription_id: blank_nil(params["subscription_id"])
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    with {:ok, customer_id} <- customer_id(params),
         {:ok, session} <- MishkaPay.portal_session(Map.put(attrs, :customer_id, customer_id)) do
      {:noreply, redirect(socket, external: session.url)}
    else
      {:error, error} -> {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="saved-cards" class="space-y-4">
      <.section_title icon="hero-credit-card" title="Saved cards and portal links" />
      <p class="text-sm opacity-70">
        Save a card for a customer without charging it, see their cards, choose the default, take
        one off. Or open Stripe's portal right on one task.
      </p>

      <div class="grid gap-4 md:grid-cols-2">
        <form
          id="saved-cards-form"
          phx-submit="cards"
          phx-target={@myself}
          class="rounded-box bg-base-200 p-4 space-y-3"
          data-testid="cards-form"
        >
          <h3 class="font-medium">Cards of one customer</h3>
          <.hint>mode: :setup checkout, MishkaPay.list_payment_methods/3</.hint>
          <.customer_picker customers={@customers} prefix="cards" />
          <div class="flex flex-wrap gap-2">
            <button
              type="submit"
              name="do"
              value="list"
              class="btn btn-sm"
              phx-disable-with="Asking Stripe..."
              data-testid="cards-list"
            >
              List saved cards
            </button>
            <button
              type="submit"
              name="do"
              value="save"
              class="btn btn-sm btn-primary"
              phx-disable-with="Opening Stripe..."
              data-testid="cards-save"
            >
              Save a card
            </button>
          </div>
        </form>

        <form
          phx-submit="portal"
          phx-target={@myself}
          class="rounded-box bg-base-200 p-4 space-y-3"
          data-testid="portal-flow-form"
        >
          <h3 class="font-medium">Portal on one task</h3>
          <.hint>MishkaPay.portal_session/1 with flow: and subscription_id:</.hint>
          <.customer_picker customers={@customers} prefix="portal" />
          <label class="fieldset">
            <span class="fieldset-legend">Task</span>
            <select name="flow" class="select select-sm" data-testid="portal-flow">
              <option value="payment_method_update">Update the card</option>
              <option value="subscription_cancel">Cancel a subscription</option>
              <option value="subscription_update">Change a subscription's plan</option>
            </select>
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Subscription (for cancel or change)</span>
            <select name="subscription_id" class="select select-sm" data-testid="portal-subscription">
              <option value="">None</option>
              <option :for={sub <- @subscriptions} value={sub.provider_id}>
                {sub.plan || "Subscription"} · {sub.customer_email || sub.customer_id} · {sub.provider_id}
              </option>
            </select>
          </label>
          <button
            class="btn btn-sm btn-primary"
            phx-disable-with="Opening Stripe..."
            data-testid="portal-flow-open"
          >
            Open the portal
          </button>
        </form>
      </div>

      <div :if={@cards} class="rounded-box bg-base-200 p-4" data-testid="cards-list-result">
        <h3 class="font-medium">
          Cards of <code class="text-sm" data-testid="cards-customer">{@customer_id}</code>
        </h3>
        <p :if={@cards == []} class="text-sm opacity-70" data-testid="cards-empty">
          No saved cards. Press "Save a card" to add one.
        </p>
        <ul class="space-y-2 mt-2">
          <li
            :for={card <- @cards}
            class="flex flex-wrap items-center gap-3 text-sm"
            data-testid="card-row"
            data-payment-method-id={card.id}
          >
            <span class="font-medium">{card.card_brand || card.type} •••• {card.card_last4}</span>
            <span :if={card.card_exp_month} class="opacity-60 text-xs">
              expires {card.card_exp_month}/{card.card_exp_year}
            </span>
            <code class="text-xs opacity-60">{card.id}</code>
            <span
              :if={card.id == @default}
              class="badge badge-success badge-sm"
              data-testid="card-default"
            >
              default
            </span>
            <button
              :if={card.id != @default}
              class="btn btn-xs"
              phx-click="make_default"
              phx-value-id={card.id}
              phx-target={@myself}
              phx-disable-with="Asking Stripe..."
              data-testid="card-make-default"
            >
              Make default
            </button>
            <button
              class="btn btn-xs btn-error btn-outline"
              phx-click="detach"
              phx-value-id={card.id}
              phx-target={@myself}
              phx-disable-with="Asking Stripe..."
              data-confirm="Take this card off the customer? It cannot be charged or saved again."
              data-testid="card-detach"
            >
              Detach
            </button>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :customers, :list, required: true
  attr :prefix, :string, required: true

  defp customer_picker(assigns) do
    ~H"""
    <div class="grid gap-2 sm:grid-cols-2">
      <label class="fieldset">
        <span class="fieldset-legend">Customer</span>
        <select name="customer" class="select select-sm" data-testid={"#{@prefix}-customer"}>
          <option value="">Pick one</option>
          <option :for={customer <- @customers} value={customer.provider_id}>
            {customer.name || customer.email || customer.provider_id}
          </option>
        </select>
      </label>
      <label class="fieldset">
        <span class="fieldset-legend">or its id</span>
        <input
          name="customer_id"
          placeholder="cus_..."
          class="input input-sm"
          data-testid={"#{@prefix}-customer-id"}
        />
      </label>
    </div>
    """
  end

  defp list(socket, customer_id) do
    tenant = socket.assigns.tenant

    with {:ok, %MishkaPay.Page{items: cards}} <-
           MishkaPay.list_payment_methods("stripe", tenant, customer_id: customer_id),
         {:ok, customer} <- MishkaPay.fetch_customer("stripe", customer_id, tenant) do
      assign(socket,
        customer_id: customer_id,
        cards: cards,
        default: customer.default_payment_method
      )
    else
      {:error, error} ->
        socket |> assign(cards: nil) |> say(:error, MishkaPay.Ash.message(error))
    end
  end

  # A card saved, not charged: Stripe's page asks for it and comes back to the shop.
  defp setup_checkout(customer_id, tenant) do
    Shop.Pay.Payment
    |> Ash.ActionInput.for_action(:start_checkout, %{
      checkout: %{
        provider: "stripe",
        tenant: tenant,
        mode: :setup,
        currency: "usd",
        customer: %{id: customer_id},
        success_url: url(~p"/") <> "?session_id={CHECKOUT_SESSION_ID}",
        cancel_url: url(~p"/?canceled=1")
      }
    })
    |> Ash.run_action(authorize?: false)
  end

  # The id typed wins over the one picked.
  defp customer_id(params) do
    case blank_nil(params["customer_id"]) || blank_nil(params["customer"]) do
      nil -> {:error, "Pick a customer, or type its id (cus_...)."}
      id -> {:ok, id}
    end
  end

  defp customers do
    Shop.Pay.Customer
    |> Ash.Query.filter(is_nil(deleted_at))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(30)
    |> Ash.read!(authorize?: false)
  end

  defp subscriptions do
    Shop.Pay.Subscription
    |> Ash.Query.filter(status not in [:canceled, :incomplete_expired])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(30)
    |> Ash.read!(authorize?: false)
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

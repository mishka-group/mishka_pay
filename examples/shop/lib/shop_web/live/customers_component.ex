defmodule ShopWeb.CustomersComponent do
  @moduledoc """
  The customers part of the demo shop, on Mishka Pay's `:customer` kind
  (`MishkaPay.Ash.Resource`): register a Stripe customer (`:register`), find customers on Stripe
  by email (`MishkaPay.list_customers/3`) and keep one (`:sync`), and open one at a time: the
  stored row beside the customer read live from Stripe (`MishkaPay.fetch_customer/3`), an edit
  form (`:edit`), its customer portal (`:portal`), and "Buy as this customer", which makes the
  next checkout pay as that customer. The page sends it each changed customer (`changed`).
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  require Ash.Query

  alias Shop.Pay.Customer

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         selected: nil,
         found: nil,
         found_next: nil,
         found_filter: [],
         saved: MapSet.new(),
         loaded?: false,
         new_open?: false
       )}

  @impl true
  def update(%{changed: record}, socket) do
    {:ok, socket |> stream_insert(:customers, record, at: 0) |> reselect(record)}
  end

  def update(assigns, socket) do
    before = socket.assigns[:buyer]
    socket = assign(socket, tenant: assigns.tenant, buyer: assigns.buyer)

    case socket.assigns.loaded? do
      true -> {:ok, rebadge(socket, before, assigns.buyer)}
      false -> {:ok, socket |> assign(loaded?: true) |> stream(:customers, newest())}
    end
  end

  @impl true
  def handle_event("toggle_new", _params, socket),
    do: {:noreply, assign(socket, new_open?: !socket.assigns.new_open?)}

  # Stripe accepts a customer with no details at all; the shop needs an email to reach them.
  def handle_event("register", params, socket) do
    args = Map.put(fields(params, ~w(email name phone reference)), :tenant, socket.assigns.tenant)

    with {:ok, args} <- needs_email(args),
         {:ok, row} <-
           Ash.create(Customer, Map.put(args, :provider, "stripe"),
             action: :register,
             authorize?: false
           ) do
      {:noreply,
       socket
       |> assign(new_open?: false)
       |> stream_insert(:customers, row, at: 0)
       |> select(row.id)
       |> say(:info, "Customer made on Stripe and saved.")}
    else
      {:error, error} -> {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("find", %{"email" => email}, socket) do
    filter = if blank?(email), do: [], else: [email: String.trim(email)]
    {:noreply, socket |> assign(found: [], found_filter: filter) |> find_page(nil)}
  end

  def handle_event("more_found", _params, socket),
    do: {:noreply, find_page(socket, socket.assigns.found_next)}

  def handle_event("close_found", _params, socket), do: {:noreply, assign(socket, found: nil)}

  def handle_event("keep", %{"customer_id" => id}, socket) do
    case sync(id, socket.assigns.tenant) do
      {:ok, row} ->
        {:noreply,
         socket
         |> stream_insert(:customers, row, at: 0)
         |> update(:saved, &MapSet.put(&1 || MapSet.new(), id))
         |> select(row.id)
         |> say(:info, "Customer read from Stripe and saved.")}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("select", %{"id" => id}, socket), do: {:noreply, select(socket, id)}

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, selected: nil)}

  def handle_event("edit", %{"customer" => id} = params, socket) do
    with {:ok, row} <- Ash.get(Customer, id, authorize?: false),
         {:ok, edited} <-
           row
           |> Ash.Changeset.for_update(:edit, edit_args(params))
           |> Ash.update(authorize?: false) do
      {:noreply,
       socket
       |> stream_insert(:customers, edited, at: 0)
       |> select(edited.id)
       |> say(:info, "Customer changed on Stripe and saved.")}
    else
      {:error, error} -> {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("sync", %{"id" => id}, socket) do
    with {:ok, row} <- Ash.get(Customer, id, authorize?: false),
         {:ok, synced} <- sync(row.provider_id, row.tenant) do
      {:noreply,
       socket
       |> stream_insert(:customers, synced, at: 0)
       |> select(synced.id)
       |> say(:info, "Customer read from Stripe and saved.")}
    else
      {:error, error} -> {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("portal", %{"id" => id}, socket) do
    Customer
    |> Ash.ActionInput.for_action(:portal, %{
      id: id,
      return_url: portal_return(socket.assigns.buyer)
    })
    |> Ash.run_action(authorize?: false)
    |> case do
      {:ok, session} -> {:noreply, redirect(socket, external: session.url)}
      {:error, error} -> {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("buy_as", %{"id" => id}, socket) do
    send(self(), {:buyer, Ash.get!(Customer, id, authorize?: false)})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="customers" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <.section_title icon="hero-user-group" title="Customers" />
        <div class="flex flex-wrap gap-2">
          <form phx-submit="find" phx-target={@myself} class="join" data-testid="find-customer-form">
            <input
              name="email"
              type="search"
              placeholder="email, or empty for the newest"
              class="input input-sm join-item"
              data-testid="find-customer-input"
            />
            <button class="btn btn-sm join-item" data-testid="find-customer-submit">
              Find on Stripe
            </button>
          </form>
          <button
            class="btn btn-sm btn-primary"
            phx-click="toggle_new"
            phx-target={@myself}
            data-testid="new-customer-toggle"
          >
            <.icon name="hero-user-plus" class="size-4" /> New customer
          </button>
        </div>
      </div>

      <.new_customer :if={@new_open?} myself={@myself} />
      <.found :if={@found} found={@found} next={@found_next} saved={@saved} myself={@myself} />

      <div class="overflow-x-auto rounded-box border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>Customer</th>
              <th>Reference</th>
              <th>Default card</th>
              <th>State</th>
              <th>Last synced</th>
            </tr>
          </thead>
          <tbody id="customers" phx-update="stream" data-testid="customer-rows">
            <tr id="customers-empty" class="only:table-row hidden">
              <td colspan="5" class="text-center opacity-70">
                No customers yet. Make one, or find one on Stripe.
              </td>
            </tr>
            <tr
              :for={{dom_id, customer} <- @streams.customers}
              id={dom_id}
              class="hover:bg-base-200 cursor-pointer"
              phx-click="select"
              phx-value-id={customer.id}
              phx-target={@myself}
              data-testid="customer-row"
              data-customer-id={customer.provider_id}
              data-deleted={to_string(deleted?(customer))}
            >
              <td>
                <div class="font-medium">{customer.name || "–"}</div>
                <div class="text-xs opacity-70">{customer.email}</div>
                <div class="text-xs opacity-60 font-mono">{customer.provider_id}</div>
              </td>
              <td class="font-mono text-xs">{customer.reference || "–"}</td>
              <td class="text-xs">{yes_no(customer.default_payment_method)}</td>
              <td><.state customer={customer} buyer={@buyer} /></td>
              <td class="text-xs opacity-70">{time(customer.synced_at)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <.details :if={@selected} selected={@selected} live={@live} buyer={@buyer} myself={@myself} />
    </section>
    """
  end

  attr :myself, :any, required: true

  defp new_customer(assigns) do
    ~H"""
    <form
      phx-submit="register"
      phx-target={@myself}
      class="card bg-base-200"
      data-testid="new-customer-form"
    >
      <div class="card-body gap-3">
        <h3 class="font-medium">New Stripe customer</h3>
        <.hint>Shop.Pay.Customer :register, MishkaPay.create_customer/1</.hint>
        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <label class="fieldset">
            <span class="fieldset-legend">Email</span>
            <input
              name="email"
              type="email"
              required
              class="input input-sm"
              data-testid="new-customer-email"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Name</span>
            <input name="name" class="input input-sm" data-testid="new-customer-name" />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Phone</span>
            <input name="phone" type="tel" class="input input-sm" data-testid="new-customer-phone" />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Reference (your user id)</span>
            <input
              name="reference"
              placeholder="user-42"
              class="input input-sm"
              data-testid="new-customer-reference"
            />
          </label>
        </div>
        <p class="text-xs opacity-70">
          The same reference sent again within a day answers the same customer. With other
          details Stripe refuses it: change a customer with Edit instead.
        </p>
        <div>
          <button
            class="btn btn-sm btn-primary"
            phx-disable-with="Asking Stripe..."
            data-testid="new-customer-submit"
          >
            Make customer
          </button>
        </div>
      </div>
    </form>
    """
  end

  attr :found, :list, required: true
  attr :next, :string, default: nil
  attr :saved, :any, required: true
  attr :myself, :any, required: true

  defp found(assigns) do
    ~H"""
    <div class="card bg-base-200" data-testid="found-customers">
      <div class="card-body gap-2">
        <div class="flex items-center gap-2">
          <h3 class="font-medium flex-1">On Stripe ({length(@found)}{if @next, do: "+"})</h3>
          <button
            class="btn btn-ghost btn-xs"
            phx-click="close_found"
            phx-target={@myself}
            aria-label="Close"
            data-testid="found-close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <.hint>MishkaPay.list_customers/3</.hint>
        <p :if={@found == []} class="text-sm opacity-70" data-testid="found-empty">
          Stripe has no customer with that email. Stripe's list leaves out customers made on a
          test clock: open those from their subscription instead.
        </p>
        <ul class="space-y-1">
          <li
            :for={customer <- @found}
            class="flex flex-wrap items-center gap-2 text-sm"
            data-testid="found-customer"
            data-customer-id={customer.id}
          >
            <span class="font-medium">{customer.name || "–"}</span>
            <span class="opacity-70">{customer.email}</span>
            <code class="text-xs opacity-60">{customer.id}</code>
            <span
              :if={MapSet.member?(@saved, customer.id)}
              class="badge badge-sm badge-success"
              data-testid="found-saved"
            >
              in the shop
            </span>
            <button
              class="btn btn-xs"
              phx-click="keep"
              phx-value-customer_id={customer.id}
              phx-target={@myself}
              phx-disable-with="Saving..."
              data-testid="found-keep"
            >
              {if MapSet.member?(@saved, customer.id), do: "Sync again", else: "Save to the shop"}
            </button>
          </li>
        </ul>
        <button
          :if={@next}
          class="btn btn-sm btn-ghost self-start"
          phx-click="more_found"
          phx-target={@myself}
          phx-disable-with="Asking Stripe..."
          data-testid="found-more"
        >
          More from Stripe
        </button>
      </div>
    </div>
    """
  end

  attr :selected, :map, required: true
  attr :live, :any, required: true
  attr :buyer, :any, required: true
  attr :myself, :any, required: true

  defp details(assigns) do
    ~H"""
    <div
      class="card bg-base-200 border border-primary/40"
      data-testid="customer-details"
      data-customer-id={@selected.provider_id}
    >
      <div class="card-body gap-4">
        <div class="flex flex-wrap items-center gap-3">
          <h3 class="card-title flex-1 min-w-0 flex-wrap">
            {@selected.name || @selected.email || "Customer"}
            <code class="text-sm opacity-70 break-all">{@selected.provider_id}</code>
          </h3>
          <a
            href={"https://dashboard.stripe.com/test/customers/#{@selected.provider_id}"}
            target="_blank"
            class="btn btn-ghost btn-sm shrink-0"
            data-testid="customer-stripe-link"
          >
            Stripe <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </a>
          <button
            class="btn btn-ghost btn-sm shrink-0"
            phx-click="close"
            phx-target={@myself}
            aria-label="Close"
            data-testid="customer-close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <div class="rounded-box bg-base-100 p-4" data-testid="customer-stored">
            <h4 class="font-medium">In the shop's database</h4>
            <.hint>Shop.Pay.Customer</.hint>
            <dl class="grid grid-cols-2 gap-y-1 text-sm mt-2">
              <dt class="opacity-70">Email</dt>
              <dd data-testid="customer-stored-email">{@selected.email || "–"}</dd>
              <dt class="opacity-70">Name</dt>
              <dd data-testid="customer-stored-name">{@selected.name || "–"}</dd>
              <dt class="opacity-70">Phone</dt>
              <dd data-testid="customer-stored-phone">{@selected.phone || "–"}</dd>
              <dt class="opacity-70">Reference</dt>
              <dd class="font-mono text-xs break-all">{@selected.reference || "–"}</dd>
              <dt class="opacity-70">State</dt>
              <dd><.state customer={@selected} buyer={@buyer} /></dd>
              <dt class="opacity-70">Made on Stripe</dt>
              <dd class="text-xs">{time(@selected.provider_created_at)}</dd>
              <dt class="opacity-70">Last synced</dt>
              <dd class="text-xs" data-testid="customer-stored-synced">
                {time(@selected.synced_at)}
              </dd>
            </dl>
          </div>

          <div class="rounded-box bg-base-100 p-4" data-testid="customer-live">
            <h4 class="font-medium">Live from Stripe</h4>
            <.hint>MishkaPay.fetch_customer/3</.hint>
            <.async_result :let={live} assign={@live}>
              <:loading>
                <span class="loading loading-dots loading-sm"></span> Asking Stripe...
              </:loading>
              <:failed :let={{:error, reason}}>
                <span class="text-error text-sm" data-testid="customer-live-error">{reason}</span>
              </:failed>
              <dl class="grid grid-cols-2 gap-y-1 text-sm mt-2">
                <dt class="opacity-70">Email</dt>
                <dd data-testid="customer-live-email">{live.email || "–"}</dd>
                <dt class="opacity-70">Name</dt>
                <dd data-testid="customer-live-name">{live.name || "–"}</dd>
                <dt class="opacity-70">Phone</dt>
                <dd>{live.phone || "–"}</dd>
                <dt class="opacity-70">Default card</dt>
                <dd class="font-mono text-xs">
                  {live.default_payment_method ||
                    "not set: a card saved at checkout shows in the portal"}
                </dd>
                <dt class="opacity-70">Metadata</dt>
                <dd class="text-xs" data-testid="customer-live-metadata">
                  <span :for={{key, value} <- live.metadata || %{}} class="block">
                    {key}: {value}
                  </span>
                  <span :if={(live.metadata || %{}) == %{}}>–</span>
                </dd>
              </dl>
            </.async_result>
          </div>
        </div>

        <p
          :if={deleted?(@selected)}
          class="rounded-box bg-base-100 p-4 text-sm"
          data-testid="customer-deleted-note"
        >
          This customer was deleted on Stripe. The shop keeps its row, marked deleted.
        </p>

        <form
          :if={!deleted?(@selected)}
          phx-submit="edit"
          phx-target={@myself}
          class="rounded-box bg-base-100 p-4"
          data-testid="customer-edit-form"
        >
          <h4 class="font-medium">Edit</h4>
          <.hint>Shop.Pay.Customer :edit, MishkaPay.update_customer/1</.hint>
          <input type="hidden" name="customer" value={@selected.id} />
          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5 items-end">
            <label class="fieldset">
              <span class="fieldset-legend">Email</span>
              <input
                name="email"
                type="email"
                value={@selected.email}
                class="input input-sm"
                data-testid="customer-edit-email"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Name</span>
              <input
                name="name"
                value={@selected.name}
                class="input input-sm"
                data-testid="customer-edit-name"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Phone</span>
              <input
                name="phone"
                type="tel"
                value={@selected.phone}
                class="input input-sm"
                data-testid="customer-edit-phone"
              />
            </label>
            <div class="fieldset">
              <span class="fieldset-legend">Metadata</span>
              <div class="join">
                <input
                  name="meta_key"
                  placeholder="key"
                  class="input input-sm join-item w-20"
                  data-testid="customer-edit-meta-key"
                />
                <input
                  name="meta_value"
                  placeholder="value"
                  class="input input-sm join-item w-24"
                  data-testid="customer-edit-meta-value"
                />
              </div>
            </div>
            <button
              class="btn btn-sm"
              phx-disable-with="Asking Stripe..."
              data-testid="customer-edit-submit"
            >
              Save on Stripe
            </button>
          </div>
        </form>

        <div class="rounded-box bg-base-100 p-4 flex flex-wrap gap-2" data-testid="customer-actions">
          <button
            :if={!deleted?(@selected)}
            class="btn btn-sm btn-primary"
            phx-click="portal"
            phx-value-id={@selected.id}
            phx-target={@myself}
            phx-disable-with="Opening..."
            data-testid="customer-portal"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open customer portal
          </button>
          <button
            :if={!deleted?(@selected)}
            class="btn btn-sm"
            phx-click={
              JS.push("buy_as", value: %{id: @selected.id}, target: @myself)
              |> JS.focus_first(to: "[data-testid=one-time-products]")
            }
            disabled={buyer?(@selected, @buyer)}
            data-testid="customer-buy-as"
          >
            <.icon name="hero-shopping-cart" class="size-4" />
            {if buyer?(@selected, @buyer), do: "Buying as this customer", else: "Buy as this customer"}
          </button>
          <button
            class="btn btn-sm"
            phx-click="sync"
            phx-value-id={@selected.id}
            phx-target={@myself}
            phx-disable-with="Asking Stripe..."
            data-testid="customer-sync"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Sync from Stripe
          </button>
          <p class="text-xs opacity-70 self-center basis-full">
            The portal is Stripe's own page: the buyer manages cards, invoices and subscriptions
            there, then comes back here.
          </p>
        </div>
      </div>
    </div>
    """
  end

  attr :customer, :map, required: true
  attr :buyer, :any, required: true

  defp state(assigns) do
    ~H"""
    <span :if={deleted?(@customer)} class="badge badge-sm badge-error" data-testid="customer-state">
      deleted on Stripe
    </span>
    <span
      :if={!deleted?(@customer) and buyer?(@customer, @buyer)}
      class="badge badge-sm badge-primary"
      data-testid="customer-state"
    >
      buying now
    </span>
    <span
      :if={!deleted?(@customer) and !buyer?(@customer, @buyer)}
      class="badge badge-sm badge-success"
      data-testid="customer-state"
    >
      active
    </span>
    """
  end

  defp sync(customer_id, tenant) do
    Ash.create(
      Customer,
      %{provider: "stripe", customer_id: customer_id, tenant: tenant},
      action: :sync,
      authorize?: false
    )
  end

  # The row now, and the customer from Stripe in the background.
  defp select(socket, id) do
    row = Ash.get!(Customer, id, authorize?: false)

    socket
    |> assign(selected: row)
    |> assign_async(
      :live,
      fn ->
        case MishkaPay.fetch_customer(row.provider, row.provider_id, row.tenant) do
          {:ok, customer} -> {:ok, %{live: customer}}
          {:error, error} -> {:error, MishkaPay.Ash.message(error)}
        end
      end,
      reset: true
    )
  end

  # A streamed row renders once: when the buyer changes, the old and the new buyer's rows are put
  # again so their badge follows.
  defp rebadge(socket, same, same), do: socket

  defp rebadge(socket, before, now) do
    [before, now]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(socket, &stream_insert(&2, :customers, &1))
  end

  defp reselect(%{assigns: %{selected: %{id: id}}} = socket, %{id: id}), do: select(socket, id)
  defp reselect(socket, _other), do: socket

  # One page of Stripe's customers, 10 at a time, added to those found before it.
  defp find_page(socket, cursor) do
    opts = [limit: 10, after: cursor] ++ socket.assigns.found_filter

    case MishkaPay.list_customers("stripe", socket.assigns.tenant, opts) do
      {:ok, %MishkaPay.Page{items: customers, next: next}} ->
        found = socket.assigns.found ++ customers
        assign(socket, found: found, found_next: next, saved: saved(found))

      {:error, error} ->
        say(socket, :error, MishkaPay.Ash.message(error))
    end
  end

  # Which of the customers found on Stripe the shop keeps already, in one read.
  defp saved(customers) do
    ids = Enum.map(customers, & &1.id)

    Customer
    |> Ash.Query.filter(provider == "stripe" and provider_id in ^ids)
    |> Ash.Query.select([:provider_id])
    |> Ash.read!(authorize?: false)
    |> MapSet.new(& &1.provider_id)
  end

  defp newest do
    Customer
    |> Ash.Query.sort(provider_created_at: :desc_nils_last, inserted_at: :desc)
    |> Ash.Query.limit(50)
    |> Ash.read!(authorize?: false)
  end

  # Only what was typed: a blank field is left as Stripe has it.
  defp fields(params, names) do
    for name <- names, not blank?(params[name]), into: %{} do
      {String.to_existing_atom(name), String.trim(params[name])}
    end
  end

  # The portal sends the buyer back here; a buyer picked before keeps buying after.
  defp portal_return(%{id: buyer}), do: url(~p"/?#{[portal: "back", buyer: buyer]}")
  defp portal_return(_no_buyer), do: url(~p"/?portal=back")

  defp needs_email(%{email: _email} = args), do: {:ok, args}
  defp needs_email(_args), do: {:error, "Type the customer's email first."}

  defp edit_args(params) do
    args = fields(params, ~w(email name phone))

    case {blank?(params["meta_key"]), blank?(params["meta_value"])} do
      {false, false} ->
        Map.put(args, :metadata, %{String.trim(params["meta_key"]) => params["meta_value"]})

      _no_metadata ->
        args
    end
  end

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end

  defp blank?(value), do: String.trim(value || "") == ""

  defp deleted?(customer), do: not is_nil(customer.deleted_at)

  defp buyer?(customer, %{id: id}), do: customer.id == id
  defp buyer?(_customer, _no_buyer), do: false

  defp yes_no(nil), do: "no"
  defp yes_no(_card), do: "yes"

  defp time(nil), do: "–"
  defp time(%DateTime{} = time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M")
end

defmodule ShopWeb.PaymentLinksComponent do
  @moduledoc """
  The payment links part of the demo shop: make a link for a product published to Stripe's
  catalog (`MishkaPay.create_payment_link/1`) with every option a developer can choose (how many
  purchases before it turns off, its message then, a quantity range, an invoice, promotion codes,
  customer creation, billing address, tax ids, a trial for a plan), list them page by page
  (`MishkaPay.list_payment_links/3`), change one (`MishkaPay.update_payment_link/1`: on or off, a
  new limit or message) and build one buyer's address (`MishkaPay.PaymentLink.url/2`). A buyer who
  pays through a link comes back to the shop like any checkout.
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @page 5
  @buyer_form %{"reference" => "", "email" => ""}

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         links: [],
         next: nil,
         open: nil,
         buyer_url: nil,
         buyer_form: @buyer_form,
         change_form: nil,
         new?: false,
         loaded?: false,
         page_size: @page
       )}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, tenant: assigns.tenant, products: published())

    case socket.assigns.loaded? do
      true -> {:ok, socket}
      false -> {:ok, socket |> assign(loaded?: true) |> first_page()}
    end
  end

  @impl true
  def handle_event("toggle_new", _params, socket),
    do: {:noreply, assign(socket, new?: !socket.assigns.new?, products: published())}

  def handle_event("create", params, socket) do
    case MishkaPay.create_payment_link(link_attrs(params, socket.assigns.tenant)) do
      {:ok, link} ->
        {:noreply,
         socket
         |> assign(new?: false, open: link.id, buyer_url: nil)
         |> first_page()
         |> say(:info, "Payment link made. Share its address anywhere.")}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("more", _params, socket), do: {:noreply, page(socket, socket.assigns.next)}

  def handle_event("open", %{"id" => id}, socket) do
    socket = assign(socket, buyer_url: nil, buyer_form: @buyer_form, change_form: nil)

    case socket.assigns.open do
      ^id -> {:noreply, assign(socket, open: nil)}
      _other -> {:noreply, assign(socket, open: id)}
    end
  end

  # The open link's two forms keep what is typed or picked: making a buyer's address must not
  # reset a change not saved yet, nor the other way round.
  def handle_event("draft_buyer", params, socket),
    do: {:noreply, assign(socket, buyer_form: buyer_form(params))}

  def handle_event("draft_link_change", params, socket),
    do: {:noreply, assign(socket, change_form: change_form(params))}

  def handle_event("change", %{"link" => id} = params, socket) do
    socket = assign(socket, change_form: change_form(params))

    attrs =
      %{
        provider: "stripe",
        tenant: socket.assigns.tenant,
        id: id,
        active: params["active"] && params["active"] == "true",
        max_purchases: integer(params["max_purchases"]),
        inactive_message: present(params["inactive_message"])
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case MishkaPay.update_payment_link(attrs) do
      {:ok, link} ->
        {:noreply,
         socket
         |> replace(link)
         |> assign(change_form: nil)
         |> say(
           :info,
           "Link #{if link.active, do: "is on", else: "is off"}, and saved on Stripe."
         )}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("buyer_url", %{"link" => id} = params, socket) do
    socket = assign(socket, buyer_form: buyer_form(params))

    link = Enum.find(socket.assigns.links, &(&1.id == id))

    opts =
      [reference: present(params["reference"]), email: present(params["email"])]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    try do
      {:noreply, assign(socket, buyer_url: MishkaPay.PaymentLink.url(link, opts))}
    rescue
      error in ArgumentError -> {:noreply, say(socket, :error, Exception.message(error))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="payment-links" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <.section_title icon="hero-link" title="Payment links" />
        <button
          class="btn btn-sm btn-primary"
          phx-click="toggle_new"
          phx-target={@myself}
          data-testid="new-link-toggle"
        >
          <.icon name="hero-plus" class="size-4" /> New payment link
        </button>
      </div>
      <p class="text-sm opacity-70">
        A page that sells a catalog price to anyone who opens it. Put it on a website, in an email
        or a QR code. Every limit is your choice: leave one empty for Stripe's default (no limit).
      </p>

      <.new_link :if={@new?} products={@products} myself={@myself} />

      <div class="overflow-x-auto rounded-box border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>Link</th>
              <th>Purchases</th>
              <th>State</th>
            </tr>
          </thead>
          <tbody data-testid="link-rows">
            <tr :if={@links == []}>
              <td colspan="3" class="text-center opacity-70" data-testid="links-empty">
                No payment links yet.
              </td>
            </tr>
            <tr
              :for={link <- @links}
              class="hover:bg-base-200 cursor-pointer"
              phx-click="open"
              phx-value-id={link.id}
              phx-target={@myself}
              data-testid="link-row"
              data-link-id={link.id}
              data-active={to_string(link.active)}
            >
              <td>
                <div class="font-mono text-xs">{link.id}</div>
                <div class="text-xs opacity-60 break-all">{link.url}</div>
              </td>
              <td class="text-sm" data-testid="link-purchases">{purchases(link)}</td>
              <td>
                <span class={["badge badge-sm", (link.active && "badge-success") || "badge-ghost"]}>
                  {if link.active, do: "on", else: "off"}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <button
        :if={@next}
        class="btn btn-sm btn-ghost"
        phx-click="more"
        phx-target={@myself}
        phx-disable-with="Asking Stripe..."
        data-testid="links-more"
      >
        Next {@page_size} from Stripe
      </button>

      <.link_card
        :for={link <- @links}
        :if={@open == link.id}
        link={link}
        buyer_url={@buyer_url}
        buyer_form={@buyer_form}
        change_form={@change_form}
        myself={@myself}
      />
    </section>
    """
  end

  attr :products, :list, required: true
  attr :myself, :any, required: true

  defp new_link(assigns) do
    ~H"""
    <form
      phx-submit="create"
      phx-target={@myself}
      class="card bg-base-200"
      data-testid="new-link-form"
    >
      <div class="card-body gap-3">
        <h3 class="font-medium">New payment link</h3>
        <.hint>MishkaPay.create_payment_link/1</.hint>
        <p :if={@products == []} class="text-sm text-warning" data-testid="link-needs-catalog">
          Publish the shop's products to Stripe first (Stripe catalog below): a link sells a
          catalog price.
        </p>
        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <label class="fieldset">
            <span class="fieldset-legend">Sells</span>
            <select name="price_id" class="select select-sm" data-testid="link-price">
              <option :for={product <- @products} value={product.stripe_price_id}>
                {product.name} (${product.price}{if product.interval, do: " / #{product.interval}"})
              </option>
            </select>
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Purchases before it turns off</span>
            <input
              name="max_purchases"
              type="number"
              min="1"
              placeholder="empty: no limit; 1: one-time"
              class="input input-sm"
              data-testid="link-max"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Message once off</span>
            <input
              name="inactive_message"
              placeholder="Sold out"
              class="input input-sm"
              data-testid="link-inactive-message"
            />
          </label>
          <div class="fieldset">
            <span class="fieldset-legend">Buyer picks the quantity</span>
            <div class="join">
              <input
                name="quantity_min"
                type="number"
                min="1"
                placeholder="min"
                class="input input-sm join-item w-20"
                data-testid="link-qty-min"
              />
              <input
                name="quantity_max"
                type="number"
                min="1"
                placeholder="max"
                class="input input-sm join-item w-20"
                data-testid="link-qty-max"
              />
            </div>
          </div>
          <label class="fieldset">
            <span class="fieldset-legend">Trial days (a plan)</span>
            <input
              name="trial_days"
              type="number"
              min="1"
              class="input input-sm"
              data-testid="link-trial"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Make a Stripe customer</span>
            <select
              name="customer_creation"
              class="select select-sm"
              data-testid="link-customer-creation"
            >
              <option value="">Stripe's choice</option>
              <option value="always">Always</option>
              <option value="if_required">Only if needed</option>
            </select>
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Billing address</span>
            <select name="billing_address" class="select select-sm" data-testid="link-billing-address">
              <option value="">Only when needed</option>
              <option value="required">Always ask</option>
            </select>
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Stripe Tax</span>
            <select name="automatic_tax" class="select select-sm" data-testid="link-automatic-tax">
              <option value="">The site's setting</option>
              <option value="on">On</option>
              <option value="off">Off</option>
            </select>
          </label>
          <div class="fieldset gap-1 sm:col-span-2">
            <label class="fieldset">
              <span class="fieldset-legend">Invoice</span>
              <select name="invoice" class="select select-sm" data-testid="link-invoice">
                <option value="">Stripe's default</option>
                <option value="on">Make one</option>
                <option value="off">Don't</option>
              </select>
              <span class="text-xs opacity-60">A merchant of record always makes one.</span>
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Merchant of record</span>
              <select name="merchant_of_record" class="select select-sm" data-testid="link-merchant">
                <option value="">The site's setting</option>
                <option value="on">On</option>
                <option value="off">Off</option>
              </select>
            </label>
            <label class="label gap-2 text-sm">
              <input
                type="checkbox"
                name="allow_promotion_codes"
                value="true"
                class="checkbox checkbox-sm"
                data-testid="link-promo"
              /> Buyers may type a promotion code
            </label>
            <label class="label gap-2 text-sm">
              <input
                type="checkbox"
                name="tax_id_collection"
                value="true"
                class="checkbox checkbox-sm"
                data-testid="link-tax-id"
              /> Business buyers give their tax id
            </label>
          </div>
        </div>
        <div>
          <button
            class="btn btn-sm btn-primary"
            disabled={@products == []}
            phx-disable-with="Asking Stripe..."
            data-testid="link-submit"
          >
            Make link
          </button>
        </div>
      </div>
    </form>
    """
  end

  attr :link, :map, required: true
  attr :buyer_url, :string, default: nil
  attr :buyer_form, :map, required: true
  attr :change_form, :map, default: nil
  attr :myself, :any, required: true

  defp link_card(assigns) do
    ~H"""
    <div
      class="card bg-base-200 border border-primary/40"
      data-testid="link-details"
      data-link-id={@link.id}
    >
      <div class="card-body gap-4">
        <div class="flex flex-wrap items-center gap-3">
          <h3 class="card-title flex-1 min-w-0 break-all">{@link.url}</h3>
          <a
            href={@link.url}
            target="_blank"
            class="btn btn-sm btn-primary"
            data-testid="link-open"
          >
            Open the link <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </a>
        </div>
        <p class="text-sm opacity-70">{options(@link)}</p>

        <form
          id={"link-buyer-form-#{@link.id}"}
          phx-change="draft_buyer"
          phx-submit="buyer_url"
          phx-target={@myself}
          class="rounded-box bg-base-100 p-4"
          data-testid="link-buyer-form"
        >
          <h4 class="font-medium">One buyer's address</h4>
          <.hint>MishkaPay.PaymentLink.url/2</.hint>
          <input type="hidden" name="link" value={@link.id} />
          <div class="flex flex-wrap items-end gap-2">
            <label class="fieldset">
              <span class="fieldset-legend">Your order or user id</span>
              <input
                name="reference"
                value={@buyer_form["reference"]}
                placeholder="order-42"
                class="input input-sm"
                data-testid="link-buyer-reference"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Buyer's email</span>
              <input
                name="email"
                type="email"
                value={@buyer_form["email"]}
                class="input input-sm"
                data-testid="link-buyer-email"
              />
            </label>
            <button class="btn btn-sm" data-testid="link-buyer-submit">Make the address</button>
          </div>
          <a
            :if={@buyer_url}
            href={@buyer_url}
            target="_blank"
            class="link text-xs break-all block mt-2"
            data-testid="link-buyer-url"
          >
            {@buyer_url}
          </a>
        </form>

        <form
          id={"link-change-form-#{@link.id}"}
          phx-change="draft_link_change"
          phx-submit="change"
          phx-target={@myself}
          class="rounded-box bg-base-100 p-4"
          data-testid="link-change-form"
        >
          <h4 class="font-medium">Change it</h4>
          <.hint>MishkaPay.update_payment_link/1</.hint>
          <input type="hidden" name="link" value={@link.id} />
          <div class="flex flex-wrap items-end gap-2">
            <label class="fieldset">
              <span class="fieldset-legend">State</span>
              <select name="active" class="select select-sm" data-testid="link-change-active">
                <option value="true" selected={changing(@change_form, @link, "active") == "true"}>
                  On
                </option>
                <option value="false" selected={changing(@change_form, @link, "active") == "false"}>
                  Off
                </option>
              </select>
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Purchases before it turns off</span>
              <input
                name="max_purchases"
                type="number"
                min="1"
                value={changing(@change_form, @link, "max_purchases")}
                class="input input-sm"
                data-testid="link-change-max"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Message once off</span>
              <input
                name="inactive_message"
                value={changing(@change_form, @link, "inactive_message")}
                class="input input-sm"
                data-testid="link-change-message"
              />
            </label>
            <button
              class="btn btn-sm"
              phx-disable-with="Asking Stripe..."
              data-testid="link-change-submit"
            >
              Save on Stripe
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp buyer_form(params), do: Map.merge(@buyer_form, Map.take(params, Map.keys(@buyer_form)))
  defp change_form(params), do: Map.take(params, ~w(active max_purchases inactive_message))

  # A change field as picked since the link was opened, or as the link has it.
  defp changing(nil, link, "active"), do: to_string(link.active)
  defp changing(nil, link, field), do: Map.get(link, String.to_existing_atom(field))
  defp changing(form, _link, field), do: form[field]

  defp first_page(socket), do: socket |> assign(links: []) |> page(nil)

  defp page(socket, cursor) do
    case MishkaPay.list_payment_links("stripe", socket.assigns.tenant,
           limit: @page,
           after: cursor
         ) do
      {:ok, %MishkaPay.Page{items: links, next: next}} ->
        assign(socket, links: socket.assigns.links ++ links, next: next)

      {:error, error} ->
        say(socket, :error, MishkaPay.Ash.message(error))
    end
  end

  defp replace(socket, link) do
    links = Enum.map(socket.assigns.links, &if(&1.id == link.id, do: link, else: &1))
    assign(socket, links: links)
  end

  defp published, do: Enum.filter(Shop.Catalog.all(), & &1.stripe_price_id)

  # Every option as typed; one left empty is Stripe's own default.
  defp link_attrs(params, tenant) do
    %{
      provider: "stripe",
      tenant: tenant,
      items: [%{id: params["price_id"], quantity: 1}],
      success_url: url(~p"/") <> "?session_id={CHECKOUT_SESSION_ID}",
      max_purchases: integer(params["max_purchases"]),
      inactive_message: present(params["inactive_message"]),
      quantity_min: integer(params["quantity_min"]),
      quantity_max: integer(params["quantity_max"]),
      trial_days: integer(params["trial_days"]),
      customer_creation: present(params["customer_creation"]),
      billing_address: present(params["billing_address"]),
      automatic_tax: on_off(params["automatic_tax"]),
      invoice: on_off(params["invoice"]),
      merchant_of_record: on_off(params["merchant_of_record"]),
      allow_promotion_codes: checked(params["allow_promotion_codes"]),
      tax_id_collection: checked(params["tax_id_collection"])
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp options(link) do
    [
      link.max_purchases && "#{link.purchases || 0} of #{link.max_purchases} purchases",
      !link.max_purchases && "no purchase limit",
      link.inactive_message && "once off: \"#{link.inactive_message}\"",
      link.invoice && "makes an invoice",
      (link.quantity_min || link.quantity_max) &&
        "buyer picks #{link.quantity_min || 1} to #{link.quantity_max || "any"}",
      link.allow_promotion_codes && "takes promotion codes",
      link.trial_days && "#{link.trial_days}-day trial",
      link.customer_creation && "customer: #{link.customer_creation}",
      link.billing_address && "billing address: #{link.billing_address}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp purchases(%{max_purchases: nil, purchases: _count}), do: "no limit"
  defp purchases(%{max_purchases: max, purchases: count}), do: "#{count || 0} of #{max}"

  defp checked("true"), do: true
  defp checked(_unchecked), do: nil

  defp on_off("on"), do: true
  defp on_off("off"), do: false
  defp on_off(_default), do: nil

  defp present(value) do
    case String.trim(value || "") do
      "" -> nil
      text -> text
    end
  end

  defp integer(value) do
    case Integer.parse(present(value) || "") do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end
end

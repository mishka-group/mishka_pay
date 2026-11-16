defmodule ShopWeb.AdminRowsComponent do
  @moduledoc """
  What a site manages from its admin, as rows in its own tables: products, prices, coupons,
  promotion codes, payment links and bills, each a resource on one of Mishka Pay's kinds
  (`mishka_pay do kind :product end` and the others, `MishkaPay.Ash.Resource`). One tab per kind
  lists its rows with their money calculations; each row reads itself again (`:resync`) and has
  its kind's row actions (archive, remove; a bill's finalize, send, paid out of band, void, mark
  uncollectible, remove); each kind has an add form that runs its `:add` action. Rows changed by
  a webhook come in live: the page sends them here (`changed`).
  """

  use ShopWeb, :live_component

  require Ash.Query

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @kinds [
    product: Shop.Pay.CatalogProduct,
    price: Shop.Pay.CatalogPrice,
    coupon: Shop.Pay.Coupon,
    promotion_code: Shop.Pay.PromotionCode,
    payment_link: Shop.Pay.PaymentLink,
    invoice: Shop.Pay.Invoice
  ]

  @labels %{
    product: "Products",
    price: "Prices",
    coupon: "Coupons",
    promotion_code: "Promotion codes",
    payment_link: "Payment links",
    invoice: "Bills"
  }

  # The money calculations each kind adds (`MishkaPay.Ash.Payment.Money`).
  @money %{
    price: [:money],
    coupon: [:money_off],
    promotion_code: [:minimum],
    invoice: [:money, :money_due]
  }

  # The update actions a row offers, besides `:resync`; a bill's depend on its status.
  @row_actions %{
    product: [archive: "Archive"],
    price: [archive: "Archive"],
    coupon: [remove: "Remove"],
    promotion_code: [],
    payment_link: []
  }

  @invoice_actions %{
    draft: [finalize: "Finalize", remove: "Remove draft"],
    open: [
      send: "Send",
      pay: "Paid out of band",
      void: "Void",
      mark_uncollectible: "Mark uncollectible"
    ],
    uncollectible: [pay: "Paid out of band", void: "Void"]
  }

  @doc "The kinds this part shows, in tab order."
  def kinds, do: Keyword.keys(@kinds)

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, kind: :product, rows: [], loaded?: false, notice: nil, error: nil)}

  @impl true
  def update(%{changed: {kind, _record}}, socket) do
    case socket.assigns.kind do
      ^kind -> {:ok, load(socket)}
      _other -> {:ok, socket}
    end
  end

  def update(assigns, socket) do
    socket = assign(socket, tenant: assigns.tenant)

    case socket.assigns.loaded? do
      true -> {:ok, socket}
      false -> {:ok, socket |> assign(loaded?: true) |> load()}
    end
  end

  @impl true
  def handle_event("kind", %{"kind" => kind}, socket) do
    kind = Enum.find(kinds(), :product, &(Atom.to_string(&1) == kind))
    {:noreply, socket |> assign(kind: kind, notice: nil, error: nil) |> load()}
  end

  def handle_event("add", params, socket) do
    %{kind: kind, tenant: tenant} = socket.assigns
    args = Map.merge(%{provider: "stripe", tenant: tenant}, add_args(kind, params))

    kind
    |> resource()
    |> Ash.Changeset.for_create(:add, args)
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, row} -> {:noreply, socket |> load() |> done("Made on Stripe: #{row.provider_id}.")}
      {:error, error} -> {:noreply, failed(socket, error)}
    end
  end

  def handle_event("act", %{"id" => id, "action" => action}, socket) do
    row = Ash.get!(resource(socket.assigns.kind), id, authorize?: false)

    case Enum.find(actions(socket.assigns.kind, row), &(Atom.to_string(&1) == action)) do
      nil -> {:noreply, assign(socket, error: "That row cannot do this now.", notice: nil)}
      action -> {:noreply, run(socket, row, action)}
    end
  end

  defp run(socket, row, action) do
    args = if action == :pay, do: %{out_of_band: true}, else: %{}

    case row |> Ash.Changeset.for_update(action, args) |> Ash.update(authorize?: false) do
      {:ok, updated} -> socket |> load() |> done(said(action, updated))
      {:error, error} -> failed(socket, error)
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, labels: @labels, all: kinds())

    ~H"""
    <section data-testid="admin-rows" class="space-y-4">
      <.section_title icon="hero-table-cells" title="Admin rows" />
      <p class="text-sm opacity-70">
        What the site keeps in its own tables, one Mishka Pay kind each. Add one here, or make it on
        Stripe: its webhook brings the row in.
      </p>
      <.hint>mishka_pay do kind :{@kind} end · {inspect(resource(@kind))} :add, :resync</.hint>

      <div role="tablist" class="tabs tabs-box tabs-sm w-fit" data-testid="admin-tabs">
        <button
          :for={kind <- @all}
          role="tab"
          class={["tab", kind == @kind && "tab-active"]}
          phx-click="kind"
          phx-value-kind={kind}
          phx-target={@myself}
          data-testid={"admin-tab-#{kind}"}
        >
          {@labels[kind]}
        </button>
      </div>

      <div :if={@notice} role="status" class="alert alert-success py-2" data-testid="admin-notice">
        {@notice}
      </div>
      <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="admin-error">
        {@error}
      </div>

      <.add_form kind={@kind} myself={@myself} rows={@rows} tenant={@tenant} />

      <div class="overflow-x-auto rounded-box border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>Stripe id</th>
              <th>What</th>
              <th>Amount</th>
              <th>State</th>
              <th></th>
            </tr>
          </thead>
          <tbody data-testid="admin-row-list" data-kind={@kind}>
            <tr :if={@rows == []}>
              <td colspan="5" class="text-center opacity-70" data-testid="admin-rows-empty">
                No {String.downcase(@labels[@kind])} kept yet.
              </td>
            </tr>
            <tr
              :for={row <- @rows}
              data-testid="admin-row"
              data-kind={@kind}
              data-provider-id={row.provider_id}
            >
              <td class="font-mono text-xs" data-testid="admin-row-id">{row.provider_id}</td>
              <td class="text-sm" data-testid="admin-row-what">{what(@kind, row)}</td>
              <td data-testid="admin-row-amount">{amount(@kind, row)}</td>
              <td>
                <span
                  class={["badge badge-sm", state_class(@kind, row)]}
                  data-testid="admin-row-state"
                >
                  {state(@kind, row)}
                </span>
              </td>
              <td class="whitespace-nowrap space-x-1">
                <button
                  class="btn btn-xs"
                  phx-click="act"
                  phx-value-id={row.id}
                  phx-value-action="resync"
                  phx-target={@myself}
                  phx-disable-with="Reading..."
                  data-testid="admin-resync"
                >
                  <.icon name="hero-arrow-path" class="size-3" /> Read again
                </button>
                <button
                  :for={{action, label} <- row_actions(@kind, row)}
                  class={["btn btn-xs", danger?(action) && "btn-error btn-outline"]}
                  phx-click="act"
                  phx-value-id={row.id}
                  phx-value-action={action}
                  phx-target={@myself}
                  phx-disable-with="Asking Stripe..."
                  data-confirm={danger?(action) && "#{label}? This cannot be undone."}
                  data-testid={"admin-#{action}"}
                >
                  {label}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :kind, :atom, required: true
  attr :myself, :any, required: true
  attr :rows, :list, required: true
  attr :tenant, :string, required: true

  defp add_form(assigns) do
    ~H"""
    <form
      id={"admin-add-#{@kind}"}
      phx-submit="add"
      phx-target={@myself}
      class="card bg-base-200"
      data-testid="admin-add-form"
      data-kind={@kind}
    >
      <div class="card-body gap-3">
        <h3 class="font-medium">Add one</h3>
        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <.add_fields kind={@kind} tenant={@tenant} />
        </div>
        <div>
          <button
            class="btn btn-sm btn-primary"
            phx-disable-with="Asking Stripe..."
            data-testid="admin-add-submit"
          >
            Add
          </button>
        </div>
      </div>
    </form>
    """
  end

  attr :kind, :atom, required: true
  attr :tenant, :string, required: true

  defp add_fields(%{kind: :product} = assigns) do
    ~H"""
    <.field name="name" label="Name" placeholder="Elixir ebook" required />
    <.field name="tax_code" label="Tax code (optional)" placeholder="txcd_10302000" />
    """
  end

  defp add_fields(%{kind: :price} = assigns) do
    assigns = assign(assigns, ids: ids(:product, assigns.tenant))

    ~H"""
    <.field
      name="product_id"
      label="Product id"
      placeholder="prod_..."
      list="admin-product-ids"
      required
    />
    <datalist id="admin-product-ids">
      <option :for={id <- @ids} value={id} />
    </datalist>
    <.field name="amount" label="Amount" placeholder="9.99" type="number" step="0.01" required />
    <.currency />
    <label class="fieldset">
      <span class="fieldset-legend">Charged</span>
      <select name="interval" class="select select-sm" data-testid="admin-add-interval">
        <option value="">Once</option>
        <option value="month">Every month</option>
        <option value="year">Every year</option>
      </select>
    </label>
    """
  end

  defp add_fields(%{kind: :coupon} = assigns) do
    ~H"""
    <.field name="name" label="Name (optional)" placeholder="Spring sale" />
    <.field name="percent_off" label="Percent off" placeholder="20" type="number" step="0.01" />
    <.field name="amount_off" label="or amount off, USD" placeholder="5.00" type="number" step="0.01" />
    <label class="fieldset">
      <span class="fieldset-legend">For</span>
      <select name="duration" class="select select-sm" data-testid="admin-add-duration">
        <option value="once">One payment</option>
        <option value="repeating">Some months</option>
        <option value="forever">Forever</option>
      </select>
    </label>
    <.field name="duration_in_months" label="Months (with some months)" type="number" />
    """
  end

  defp add_fields(%{kind: :promotion_code} = assigns) do
    assigns = assign(assigns, ids: ids(:coupon, assigns.tenant))

    ~H"""
    <.field name="coupon_id" label="Coupon id" list="admin-coupon-ids" required />
    <datalist id="admin-coupon-ids">
      <option :for={id <- @ids} value={id} />
    </datalist>
    <.field name="code" label="Code buyers type (optional)" placeholder="SPRING20" />
    """
  end

  defp add_fields(%{kind: :payment_link} = assigns) do
    assigns = assign(assigns, ids: ids(:price, assigns.tenant))

    ~H"""
    <.field name="price_id" label="Price id" placeholder="price_..." list="admin-price-ids" required />
    <datalist id="admin-price-ids">
      <option :for={id <- @ids} value={id} />
    </datalist>
    """
  end

  defp add_fields(%{kind: :invoice} = assigns) do
    assigns = assign(assigns, ids: customer_ids(assigns.tenant))

    ~H"""
    <.field
      name="customer_id"
      label="Customer id"
      placeholder="cus_..."
      list="admin-customer-ids"
      required
    />
    <datalist id="admin-customer-ids">
      <option :for={id <- @ids} value={id} />
    </datalist>
    <.field name="item" label="Item" placeholder="Setup work" required />
    <.field name="amount" label="Amount" placeholder="50.00" type="number" step="0.01" required />
    <.currency />
    <label class="fieldset">
      <span class="fieldset-legend">Paid by</span>
      <select name="collection" class="select select-sm" data-testid="admin-add-collection">
        <option value="send_invoice">Bill sent by email</option>
        <option value="charge_automatically">Saved card, on finalize</option>
      </select>
    </label>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :rest, :global, include: ~w(placeholder type step list required)

  defp field(assigns) do
    ~H"""
    <label class="fieldset">
      <span class="fieldset-legend">{@label}</span>
      <input name={@name} class="input input-sm" data-testid={"admin-add-#{@name}"} {@rest} />
    </label>
    """
  end

  defp currency(assigns) do
    ~H"""
    <label class="fieldset">
      <span class="fieldset-legend">Currency</span>
      <select name="currency" class="select select-sm" data-testid="admin-add-currency">
        <option value="USD">USD</option>
        <option value="EUR">EUR</option>
        <option value="GBP">GBP</option>
      </select>
    </label>
    """
  end

  # The `:add` arguments of each kind from its form; a blank field is left out.
  defp add_args(:product, params), do: given(params, name: "name", tax_code: "tax_code")

  defp add_args(:price, params) do
    params
    |> given(product_id: "product_id", interval: "interval")
    |> Map.put(:amount, money(params))
  end

  defp add_args(:coupon, params) do
    params
    |> given(
      name: "name",
      percent_off: "percent_off",
      duration: "duration",
      duration_in_months: "duration_in_months"
    )
    |> put_given(:amount_off, filled(params["amount_off"]) && money(params, "amount_off", "USD"))
  end

  defp add_args(:promotion_code, params), do: given(params, coupon_id: "coupon_id", code: "code")

  defp add_args(:payment_link, params),
    do: %{link: %{items: [%{id: filled(params["price_id"]), quantity: 1}]}}

  defp add_args(:invoice, params) do
    %{
      draft: %{
        customer_id: filled(params["customer_id"]),
        collection: params["collection"] || "send_invoice",
        items: [%{name: filled(params["item"]), amount: money(params), quantity: 1}]
      }
    }
  end

  defp given(params, fields) do
    Enum.reduce(fields, %{}, fn {name, key}, acc -> put_given(acc, name, filled(params[key])) end)
  end

  defp put_given(map, _name, nil), do: map
  defp put_given(map, name, value), do: Map.put(map, name, value)

  defp money(params, key \\ "amount", currency \\ nil),
    do: %{amount: filled(params[key]), currency: currency || params["currency"] || "USD"}

  defp filled(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp filled(_none), do: nil

  defp load(%{assigns: %{kind: kind, tenant: tenant}} = socket) do
    rows =
      kind
      |> resource()
      |> Ash.Query.filter(tenant == ^tenant)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.load(Map.get(@money, kind, []))
      |> Ash.Query.limit(50)
      |> Ash.read!(authorize?: false)

    assign(socket, rows: rows)
  end

  # Ids the site already keeps, offered in the add forms.
  defp ids(kind, tenant) do
    kind
    |> resource()
    |> Ash.Query.filter(tenant == ^tenant and is_nil(deleted_at))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(20)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.provider_id)
  end

  defp customer_ids(tenant) do
    Shop.Pay.Customer
    |> Ash.Query.filter(tenant == ^tenant and is_nil(deleted_at))
    |> Ash.Query.limit(20)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.provider_id)
  end

  defp resource(kind), do: Keyword.fetch!(@kinds, kind)

  defp actions(kind, row), do: [:resync | Keyword.keys(row_actions(kind, row))]

  defp row_actions(_kind, %{deleted_at: %DateTime{}}), do: []
  defp row_actions(:invoice, row), do: Map.get(@invoice_actions, row.status, [])
  defp row_actions(kind, %{active: false}) when kind in [:product, :price], do: []
  defp row_actions(kind, _row), do: Map.fetch!(@row_actions, kind)

  defp danger?(action), do: action in [:remove, :void, :mark_uncollectible]

  defp what(:product, row), do: row.name
  defp what(:price, row), do: "#{row.product_id}#{every(row.interval)}"
  defp what(:coupon, row), do: row.name || duration(row)
  defp what(:promotion_code, row), do: "#{row.code} for #{row.coupon_id}"
  defp what(:payment_link, row), do: row.url
  defp what(:invoice, row), do: "#{row.number || "draft"} for #{row.customer_id}"

  defp every(nil), do: ""
  defp every(interval), do: " every #{interval}"

  defp duration(row), do: "#{row.duration}"

  defp amount(:price, row), do: money_text(row.money)

  defp amount(:coupon, %{percent_off: %Decimal{} = percent}),
    do: "#{Decimal.normalize(percent)}% off"

  defp amount(:coupon, row), do: "#{money_text(row.money_off)} off"

  defp amount(:promotion_code, %{minimum: %Money{} = minimum}),
    do: "from #{money_text(minimum)}"

  defp amount(:invoice, row), do: "#{money_text(row.money)} (due #{money_text(row.money_due)})"
  defp amount(_kind, _row), do: "–"

  defp money_text(%Money{} = money), do: Money.to_string!(money)
  defp money_text(_none), do: "–"

  defp state(_kind, %{deleted_at: %DateTime{}}), do: "removed"
  defp state(:invoice, row), do: row.status
  defp state(:coupon, row), do: if(row.valid, do: "can be used", else: "used up")
  defp state(_kind, row), do: if(row.active, do: "active", else: "off")

  defp state_class(_kind, %{deleted_at: %DateTime{}}), do: "badge-ghost"
  defp state_class(:invoice, %{status: :paid}), do: "badge-success"

  defp state_class(:invoice, %{status: status}) when status in [:void, :uncollectible],
    do: "badge-error"

  defp state_class(:invoice, _row), do: "badge-warning"
  defp state_class(:coupon, row), do: if(row.valid, do: "badge-success", else: "badge-ghost")
  defp state_class(_kind, row), do: if(row.active, do: "badge-success", else: "badge-ghost")

  defp said(:resync, row), do: "Read again from Stripe: #{row.provider_id}."
  defp said(:archive, row), do: "Archived: #{row.provider_id} is off sale."
  defp said(:remove, row), do: "Removed: #{row.provider_id}."
  defp said(:finalize, row), do: "Bill #{row.number || row.provider_id} is open for payment."
  defp said(:send, row), do: "Bill #{row.number || row.provider_id} sent to the customer."
  defp said(:pay, row), do: "Bill #{row.number || row.provider_id} marked paid out of band."
  defp said(:void, row), do: "Bill #{row.number || row.provider_id} voided."

  defp said(:mark_uncollectible, row),
    do: "Bill #{row.number || row.provider_id} marked uncollectible."

  defp done(socket, message), do: assign(socket, notice: message, error: nil)

  defp failed(socket, error), do: assign(socket, error: MishkaPay.Ash.message(error), notice: nil)
end

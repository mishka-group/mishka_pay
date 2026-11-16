defmodule ShopWeb.StripeListsComponent do
  @moduledoc """
  Every list Mishka Pay reads, page by page, the same way: payments, customers, invoices,
  products, prices, coupons and promotion codes. Each answers a `MishkaPay.Page`; "Next page"
  passes its `:next` back as `after:`, and "Read all" walks every page with
  `MishkaPay.Page.stream/1` (up to 200 items).
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @kinds [
    {"payments", "Payments", "customer id (cus_...)"},
    {"customers", "Customers", "email"},
    {"invoices", "Invoices", "customer (cus_...) or subscription (sub_...)"},
    {"products", "Products", nil},
    {"prices", "Prices", "product id"},
    {"coupons", "Coupons", nil},
    {"promotion_codes", "Promotion codes", "coupon id"}
  ]

  @most 200

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         kinds: @kinds,
         most: @most,
         reading?: false,
         kind: "payments",
         limit: "2",
         filter: "",
         items: [],
         page: 0,
         next: nil,
         cursors: [],
         total: nil
       )}

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, tenant: assigns.tenant)}

  @impl true
  def handle_event("load", params, socket) do
    socket
    |> assign(
      kind: params["kind"],
      limit: params["limit"],
      filter: String.trim(params["filter"] || ""),
      page: 0,
      cursors: [],
      total: nil
    )
    |> read(nil)
    |> then(&{:noreply, &1})
  end

  def handle_event("next", _params, socket) do
    socket
    |> assign(cursors: socket.assigns.cursors ++ [socket.assigns.next])
    |> read(socket.assigns.next)
    |> then(&{:noreply, &1})
  end

  def handle_event("first", _params, socket),
    do: {:noreply, socket |> assign(page: 0, cursors: []) |> read(nil)}

  # Reading every page asks Stripe once per 100 items, apart from the page, so it never blocks it.
  def handle_event("all", _params, socket) do
    list = list_fun(%{socket.assigns | limit: "100"})
    most = @most

    {:noreply,
     socket
     |> assign(total: nil, reading?: true)
     |> start_async(:all, fn -> list |> MishkaPay.Page.stream() |> Enum.take(most) |> length() end)}
  end

  @impl true
  def handle_async(:all, {:ok, count}, socket),
    do: {:noreply, assign(socket, total: count, reading?: false)}

  def handle_async(:all, {:exit, {error, _stack}}, socket) when is_exception(error) do
    {:noreply, socket |> assign(reading?: false) |> say(:error, MishkaPay.Ash.message(error))}
  end

  def handle_async(:all, {:exit, reason}, socket),
    do: {:noreply, socket |> assign(reading?: false) |> say(:error, inspect(reason))}

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="stripe-lists" class="space-y-3">
      <.section_title icon="hero-queue-list" title="Browse Stripe lists" />
      <.hint>MishkaPay.list_* answers MishkaPay.Page; MishkaPay.Page.stream/1 reads them all</.hint>

      <form
        phx-submit="load"
        phx-target={@myself}
        class="flex flex-wrap items-end gap-2"
        data-testid="lists-form"
      >
        <label class="fieldset">
          <span class="fieldset-legend">List</span>
          <select name="kind" class="select select-sm" data-testid="lists-kind">
            <option :for={{value, label, _hint} <- @kinds} value={value} selected={value == @kind}>
              {label}
            </option>
          </select>
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">A page holds</span>
          <select name="limit" class="select select-sm" data-testid="lists-limit">
            <option :for={n <- ~w(1 2 5 10 25)} value={n} selected={n == @limit}>{n}</option>
          </select>
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">Only (optional)</span>
          <input
            name="filter"
            value={@filter}
            placeholder={filter_hint(@kinds, @kind)}
            class="input input-sm w-64"
            data-testid="lists-filter"
          />
        </label>
        <button
          class="btn btn-sm btn-primary"
          phx-disable-with="Asking Stripe..."
          data-testid="lists-load"
        >
          Read first page
        </button>
      </form>

      <div class="flex flex-wrap items-center gap-2 text-sm" data-testid="lists-pager">
        <span data-testid="lists-page">Page {@page}</span>
        <span class="opacity-60">· {length(@items)} on it</span>
        <button
          :if={@page > 1}
          class="btn btn-xs"
          phx-click="first"
          phx-target={@myself}
          data-testid="lists-first"
        >
          First page
        </button>
        <button
          :if={@next}
          class="btn btn-xs btn-primary"
          phx-click="next"
          phx-target={@myself}
          phx-disable-with="Asking Stripe..."
          data-testid="lists-next"
        >
          Next page
        </button>
        <span :if={@page > 0 and !@next} class="opacity-60" data-testid="lists-last">
          last page
        </span>
        <button
          :if={@page > 0}
          class="btn btn-xs btn-ghost"
          phx-click="all"
          phx-target={@myself}
          disabled={@reading?}
          data-testid="lists-all"
        >
          {if @reading?, do: "Reading every page...", else: "Read all (up to #{@most}), 100 a page"}
        </button>
        <span :if={@total} data-testid="lists-total">
          {@total} in all{if @total == @most, do: " or more"}
        </span>
      </div>

      <div :if={@page > 0} class="overflow-x-auto rounded-box border border-base-300">
        <table class="table table-sm">
          <tbody data-testid="lists-rows">
            <tr :if={@items == []}>
              <td class="opacity-70" data-testid="lists-empty">Nothing on Stripe here.</td>
            </tr>
            <tr :for={item <- @items} data-testid="lists-row" data-id={item.id}>
              <td class="font-mono text-xs">{item.id}</td>
              <td class="text-sm">{summary(item)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp read(socket, cursor) do
    case list_fun(socket.assigns).(after: cursor) do
      {:ok, %MishkaPay.Page{items: items, next: next}} ->
        assign(socket, items: items, next: next, page: socket.assigns.page + 1)

      {:error, error} ->
        socket |> assign(items: [], next: nil) |> say(:error, MishkaPay.Ash.message(error))
    end
  end

  # The list call of the chosen kind, as a function of the paging options, with the page size
  # and the filter set.
  defp list_fun(%{kind: kind, limit: limit, filter: filter, tenant: tenant}) do
    base = [limit: String.to_integer(limit)] ++ filter(kind, filter)
    call = call(kind)
    fn opts -> call.("stripe", tenant, Keyword.merge(base, opts)) end
  end

  defp call("payments"), do: &MishkaPay.list_payments/3
  defp call("customers"), do: &MishkaPay.list_customers/3
  defp call("invoices"), do: &MishkaPay.list_invoices/3
  defp call("products"), do: &MishkaPay.list_products/3
  defp call("prices"), do: &MishkaPay.list_prices/3
  defp call("coupons"), do: &MishkaPay.list_coupons/3
  defp call("promotion_codes"), do: &MishkaPay.list_promotion_codes/3

  defp filter(_kind, ""), do: []
  defp filter("payments", id), do: [customer_id: id]
  defp filter("customers", email), do: [email: email]
  defp filter("invoices", "sub_" <> _ = id), do: [subscription_id: id]
  defp filter("invoices", id), do: [customer_id: id]
  defp filter("prices", id), do: [product_id: id]
  defp filter("promotion_codes", id), do: [coupon_id: id]
  defp filter(_kind, _ignored), do: []

  defp filter_hint(kinds, kind) do
    Enum.find_value(kinds, "no filter", fn {value, _label, hint} ->
      value == kind && (hint || "no filter")
    end)
  end

  defp summary(%MishkaPay.Payment{} = p),
    do: "#{money(p.amount)} · #{p.status} · #{p.customer_email || "no email"}"

  defp summary(%MishkaPay.Customer{} = c), do: "#{c.name || "–"} · #{c.email || "no email"}"
  defp summary(%MishkaPay.Invoice{} = i), do: "#{money(i.amount_due)} · #{i.status}"

  defp summary(%MishkaPay.Product{} = p),
    do: "#{p.name} · #{if p.active, do: "on sale", else: "archived"}"

  defp summary(%MishkaPay.Price{} = p), do: "#{p.name || "–"} · #{money(p.amount)}"
  defp summary(%MishkaPay.Coupon{} = c), do: "#{c.name || "–"} · used #{c.times_redeemed || 0}"

  defp summary(%MishkaPay.PromotionCode{} = c),
    do: "#{c.code} · #{if c.active, do: "on", else: "off"}"

  defp money(nil), do: "–"
  defp money(amount), do: Money.to_string!(amount)

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end
end

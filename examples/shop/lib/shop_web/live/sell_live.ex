defmodule ShopWeb.SellLive do
  @moduledoc """
  The admin's whole flow on one page: describe a product with every field Stripe takes, press one
  button, and get the link a buyer opens to pay. The button runs three Mishka Pay calls in order,
  each shown as it happens:

    1. `MishkaPay.create_product/1`: the product in Stripe's catalog;
    2. `MishkaPay.create_price/1`: its price, once or on a schedule;
    3. `MishkaPay.create_payment_link/1`: the page that sells it, with the limits chosen.

  A step that fails stops the run and says why; nothing after it runs. The steps run apart from
  the page (`start_async`), so the page stays live while Stripe answers.

  "Undo" reverses whatever the run made, newest first: the link is turned off
  (`MishkaPay.update_payment_link/1` with `active: false`), the price archived
  (`MishkaPay.archive_price/3`) and the product archived (`MishkaPay.archive_product/3`). Stripe
  never deletes a price or a link, nor a product that has a price, so off sale is as far as undo
  goes: nothing of it can be bought again, and Stripe keeps it for its records.
  """

  use ShopWeb, :live_view

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @tenant "demo"

  @currencies ~w(USD EUR GBP CAD AUD)
  @tax_codes [
    {"txcd_10302000", "Digital book"},
    {"txcd_10103001", "Software as a service"},
    {"txcd_10201000", "Video, streamed"},
    {"txcd_20030000", "General services"},
    {"txcd_99999999", "General, tangible goods"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Sell a product with one link",
       tenant: @tenant,
       currencies: @currencies,
       tax_codes: @tax_codes,
       params: %{"currency" => "USD", "interval" => "month"},
       steps: [],
       undo_steps: [],
       made: %{},
       running?: false,
       link: nil,
       buyer_url: nil
     )}
  end

  @impl true
  def handle_event("change", params, socket), do: {:noreply, assign(socket, params: params)}

  def handle_event("sell", params, socket) do
    me = self()
    tenant = @tenant
    success_url = url(~p"/") <> "?session_id={CHECKOUT_SESSION_ID}"

    {:noreply,
     socket
     |> assign(params: params, steps: [], undo_steps: [], made: %{}, running?: true)
     |> assign(link: nil, buyer_url: nil)
     |> start_async(:sell, fn -> run(me, params, tenant, success_url) end)}
  end

  def handle_event("undo", _params, %{assigns: %{made: made}} = socket) when made != %{} do
    me = self()
    tenant = @tenant

    {:noreply,
     socket
     |> assign(undo_steps: [], running?: true)
     |> start_async(:undo, fn -> undo(me, made, tenant) end)}
  end

  def handle_event("undo", _params, socket), do: {:noreply, socket}

  def handle_event("buyer_url", params, %{assigns: %{link: link}} = socket)
      when not is_nil(link) do
    opts =
      [reference: present(params["reference"]), email: present(params["email"])]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    try do
      {:noreply, assign(socket, buyer_url: MishkaPay.PaymentLink.url(link, opts))}
    rescue
      error in ArgumentError -> {:noreply, put_flash(socket, :error, Exception.message(error))}
    end
  end

  @impl true
  def handle_info({:step, list, step}, socket) do
    steps = Enum.reject(socket.assigns[list], &(&1.n == step.n)) ++ [step]
    {:noreply, assign(socket, [{list, Enum.sort_by(steps, & &1.n)}])}
  end

  def handle_info({:made, kind, struct}, socket),
    do: {:noreply, assign(socket, made: Map.put(socket.assigns.made, kind, struct))}

  @impl true
  def handle_async(:sell, {:ok, {:ok, link}}, socket),
    do: {:noreply, assign(socket, running?: false, link: link)}

  def handle_async(:sell, {:ok, {:error, _stopped}}, socket),
    do: {:noreply, assign(socket, running?: false)}

  def handle_async(:undo, {:ok, result}, socket) do
    made = if match?({:ok, _all}, result), do: %{}, else: socket.assigns.made
    {:noreply, assign(socket, running?: false, made: made, link: nil, buyer_url: nil)}
  end

  def handle_async(_run, {:exit, reason}, socket) do
    {:noreply,
     socket |> assign(running?: false) |> put_flash(:error, "The run stopped: #{inspect(reason)}")}
  end

  # The three calls, each reported to the page before and after it runs; what each made is kept
  # for undo, so a run that stopped halfway can still be undone.
  defp run(page, params, tenant, success_url) do
    with {:ok, product} <-
           make(page, :product, 1, "Make the product", "MishkaPay.create_product/1", fn ->
             MishkaPay.create_product(product_attrs(params, tenant))
           end),
         {:ok, price} <-
           make(page, :price, 2, "Give it a price", "MishkaPay.create_price/1", fn ->
             MishkaPay.create_price(price_attrs(params, tenant, product.id))
           end) do
      make(page, :link, 3, "Make the payment link", "MishkaPay.create_payment_link/1", fn ->
        MishkaPay.create_payment_link(link_attrs(params, tenant, price.id, success_url))
      end)
    end
  end

  defp make(page, kind, n, title, call, fun) do
    with {:ok, struct} = made <- step(page, :steps, n, title, call, fun) do
      send(page, {:made, kind, struct})
      made
    end
  end

  # Newest first, and only what was made; one that fails stops the rest so it can be tried again.
  defp undo(page, made, tenant) do
    [
      {:link, "Turn the payment link off", "MishkaPay.update_payment_link/1 (active: false)",
       &MishkaPay.update_payment_link(%{
         provider: "stripe",
         tenant: tenant,
         id: &1.id,
         active: false
       })},
      {:price, "Archive the price", "MishkaPay.archive_price/3",
       &MishkaPay.archive_price("stripe", &1.id, tenant)},
      {:product, "Archive the product", "MishkaPay.archive_product/3",
       &MishkaPay.archive_product("stripe", &1.id, tenant)}
    ]
    |> Enum.filter(fn {kind, _title, _call, _fun} -> Map.has_key?(made, kind) end)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {{kind, title, call, fun}, n}, {:ok, done} ->
      case step(page, :undo_steps, n, title, call, fn -> fun.(made[kind]) end) do
        {:ok, struct} -> {:cont, {:ok, [struct | done]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp step(page, list, n, title, call, fun) do
    started = System.monotonic_time(:millisecond)
    running = %{n: n, title: title, call: call, state: :running, detail: nil, ms: nil}
    send(page, {:step, list, running})
    result = fun.()
    ms = System.monotonic_time(:millisecond) - started

    {state, detail} =
      case result do
        {:ok, struct} -> {:done, summary(struct)}
        {:error, error} -> {:failed, MishkaPay.Ash.message(error)}
      end

    send(page, {:step, list, %{running | state: state, detail: detail, ms: ms}})
    result
  end

  defp summary(%MishkaPay.Product{} = product),
    do:
      "#{product.id} · #{product.name}#{product.tax_code && " · #{product.tax_code}"}#{on_sale(product)}"

  defp summary(%MishkaPay.Price{} = price) do
    every =
      if price.interval,
        do: " every #{price.interval_count || 1} #{price.interval}",
        else: " once"

    "#{price.id} · #{Money.to_string!(price.amount)}#{every}" <>
      if(price.tax_behavior, do: " · tax #{price.tax_behavior}", else: "") <> on_sale(price)
  end

  defp summary(%MishkaPay.PaymentLink{} = link), do: "#{link.id} · #{link.url}#{on_sale(link)}"

  defp on_sale(%{active: false}), do: " · off sale"
  defp on_sale(_on), do: ""

  # Each struct takes only what was filled in; the rest is Stripe's default.
  defp product_attrs(params, tenant) do
    compact(%{
      provider: "stripe",
      tenant: tenant,
      id: present(params["product_id"]),
      name: present(params["name"]),
      description: present(params["description"]),
      tax_code: present(params["tax_code"]),
      metadata: metadata(params)
    })
  end

  defp price_attrs(params, tenant, product_id) do
    interval = present(params["interval"])

    compact(%{
      provider: "stripe",
      tenant: tenant,
      product_id: product_id,
      amount: %{amount: present(params["amount"]), currency: params["currency"]},
      interval: interval,
      interval_count: interval && integer(params["interval_count"]),
      tax_behavior: present(params["tax_behavior"]),
      lookup_key: present(params["lookup_key"])
    })
  end

  defp link_attrs(params, tenant, price_id, success_url) do
    compact(%{
      provider: "stripe",
      tenant: tenant,
      items: [%{id: price_id, quantity: integer(params["quantity"]) || 1}],
      success_url: success_url,
      max_purchases: integer(params["max_purchases"]),
      inactive_message: present(params["inactive_message"]),
      quantity_min: integer(params["quantity_min"]),
      quantity_max: integer(params["quantity_max"]),
      trial_days: present(params["interval"]) && integer(params["trial_days"]),
      allow_promotion_codes: checked(params["allow_promotion_codes"]),
      automatic_tax: on_off(params["automatic_tax"]),
      merchant_of_record: on_off(params["merchant_of_record"]),
      invoice: on_off(params["invoice"]),
      customer_creation: present(params["customer_creation"]),
      billing_address: present(params["billing_address"]),
      tax_id_collection: checked(params["tax_id_collection"])
    })
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center gap-3 mb-4">
        <.link navigate={~p"/"} class="btn btn-ghost btn-sm" data-testid="sell-back">
          <.icon name="hero-arrow-left" class="size-4" /> Back to the shop
        </.link>
        <h1 class="text-2xl font-semibold">Sell a product with one link</h1>
      </div>
      <p class="opacity-70 mb-6 max-w-3xl">
        Describe what you sell, press the button, and Mishka Pay makes the product, its price and a
        payment link at Stripe, in that order. You get a link to put on any page, email or QR code.
        Every field left empty is Stripe's own default.
      </p>

      <form phx-change="change" phx-submit="sell" class="space-y-6" data-testid="sell-form">
        <section class="card bg-base-200" data-testid="sell-product">
          <div class="card-body">
            <.section_title icon="hero-cube" title="1. The product" />
            <.hint>MishkaPay.create_product/1 · Stripe Product</.hint>
            <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
              <.field
                params={@params}
                name="name"
                label="Name the buyer sees"
                required
                placeholder="Mishka CMS Support"
                testid="sell-name"
              />
              <.field
                params={@params}
                name="product_id"
                label="Own id (optional)"
                placeholder="mishka-cms-support"
                testid="sell-product-id"
              />
              <.choice
                params={@params}
                name="tax_code"
                label="Tax category"
                testid="sell-tax-code"
                options={[
                  {"", "Stripe's default"}
                  | for({code, label} <- @tax_codes, do: {code, "#{label} (#{code})"})
                ]}
              />
              <label class="fieldset sm:col-span-2 lg:col-span-3">
                <span class="fieldset-legend">Description</span>
                <textarea
                  name="description"
                  class="textarea textarea-sm"
                  placeholder="Priority answers and fixes for your Mishka CMS site"
                  data-testid="sell-description"
                >{@params["description"]}</textarea>
              </label>
              <div class="fieldset">
                <span class="fieldset-legend">Metadata (optional)</span>
                <div class="join">
                  <input
                    name="meta_key"
                    value={@params["meta_key"]}
                    placeholder="key"
                    class="input input-sm join-item w-24"
                    data-testid="sell-meta-key"
                  />
                  <input
                    name="meta_value"
                    value={@params["meta_value"]}
                    placeholder="value"
                    class="input input-sm join-item w-28"
                    data-testid="sell-meta-value"
                  />
                </div>
              </div>
            </div>
          </div>
        </section>

        <section class="card bg-base-200" data-testid="sell-price">
          <div class="card-body">
            <.section_title icon="hero-banknotes" title="2. The price" />
            <.hint>MishkaPay.create_price/1 · Stripe Price</.hint>
            <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <.field
                params={@params}
                name="amount"
                label="Amount"
                required
                type="number"
                step="0.01"
                min="0.5"
                placeholder="20.00"
                testid="sell-amount"
              />
              <.choice
                params={@params}
                name="currency"
                label="Currency"
                testid="sell-currency"
                options={for currency <- @currencies, do: {currency, currency}}
              />
              <.choice
                params={@params}
                name="interval"
                label="Charged"
                testid="sell-interval"
                options={[
                  {"", "Once"},
                  {"day", "Every day"},
                  {"week", "Every week"},
                  {"month", "Every month"},
                  {"year", "Every year"}
                ]}
              />
              <.field
                params={@params}
                name="interval_count"
                label="Every how many (plans)"
                type="number"
                min="1"
                placeholder="1"
                testid="sell-interval-count"
              />
              <.choice
                params={@params}
                name="tax_behavior"
                label="Tax in the amount"
                testid="sell-tax-behavior"
                options={[
                  {"", "Stripe's default"},
                  {"exclusive", "Added on top"},
                  {"inclusive", "Already included"}
                ]}
              />
              <.field
                params={@params}
                name="lookup_key"
                label="Your name for it (lookup key)"
                placeholder="cms-support-monthly"
                testid="sell-lookup-key"
              />
            </div>
          </div>
        </section>

        <section class="card bg-base-200" data-testid="sell-link">
          <div class="card-body">
            <.section_title icon="hero-link" title="3. The payment link" />
            <.hint>MishkaPay.create_payment_link/1 · Stripe Payment Link</.hint>
            <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <.field
                params={@params}
                name="quantity"
                label="Quantity"
                type="number"
                min="1"
                placeholder="1"
                testid="sell-quantity"
              />
              <.field
                params={@params}
                name="max_purchases"
                label="Purchases before it turns off"
                type="number"
                min="1"
                placeholder="empty: no limit; 1: one-time"
                testid="sell-max"
              />
              <.field
                params={@params}
                name="inactive_message"
                label="Message once off"
                placeholder="Sold out"
                testid="sell-inactive-message"
              />
              <.field
                params={@params}
                name="trial_days"
                label="Trial days (plans)"
                type="number"
                min="1"
                testid="sell-trial"
              />
              <.field
                params={@params}
                name="quantity_min"
                label="Buyer picks quantity: from"
                type="number"
                min="1"
                testid="sell-qty-min"
              />
              <.field
                params={@params}
                name="quantity_max"
                label="to"
                type="number"
                min="2"
                testid="sell-qty-max"
              />
              <.choice
                params={@params}
                name="invoice"
                label="Invoice"
                testid="sell-invoice"
                options={[{"", "Stripe's default"}, {"on", "Make one"}, {"off", "Don't"}]}
              />
              <.choice
                params={@params}
                name="merchant_of_record"
                label="Merchant of record"
                testid="sell-merchant"
                options={[{"", "The site's setting"}, {"on", "On"}, {"off", "Off"}]}
              />
              <.choice
                params={@params}
                name="automatic_tax"
                label="Stripe Tax"
                testid="sell-automatic-tax"
                options={[{"", "The site's setting"}, {"on", "On"}, {"off", "Off"}]}
              />
              <.choice
                params={@params}
                name="customer_creation"
                label="Make a Stripe customer"
                testid="sell-customer-creation"
                options={[
                  {"", "Stripe's choice"},
                  {"always", "Always"},
                  {"if_required", "Only if needed"}
                ]}
              />
              <.choice
                params={@params}
                name="billing_address"
                label="Billing address"
                testid="sell-billing-address"
                options={[{"", "Only when needed"}, {"required", "Always ask"}]}
              />
              <div class="fieldset gap-1">
                <label class="label gap-2 text-sm">
                  <input
                    type="checkbox"
                    name="allow_promotion_codes"
                    value="true"
                    checked={@params["allow_promotion_codes"] == "true"}
                    class="checkbox checkbox-sm"
                    data-testid="sell-promo"
                  /> Buyers may type a promotion code
                </label>
                <label class="label gap-2 text-sm">
                  <input
                    type="checkbox"
                    name="tax_id_collection"
                    value="true"
                    checked={@params["tax_id_collection"] == "true"}
                    class="checkbox checkbox-sm"
                    data-testid="sell-tax-id"
                  /> Business buyers give their tax id
                </label>
              </div>
            </div>
          </div>
        </section>

        <button
          class="btn btn-primary btn-lg w-full sm:w-auto"
          disabled={@running?}
          data-testid="sell-submit"
        >
          <span :if={@running?} class="loading loading-spinner"></span>
          <.icon :if={!@running?} name="hero-bolt" class="size-5" />
          {if @running?, do: "Asking Stripe...", else: "Make the product and its buy link"}
        </button>
      </form>

      <.steps :if={@steps != []} steps={@steps} title="What happened" testid="sell-steps" />

      <section
        :if={@made != %{} and !@running?}
        class="card bg-base-200 mt-6"
        data-testid="sell-undo"
      >
        <div class="card-body gap-2">
          <.section_title icon="hero-arrow-uturn-left" title="Undo" />
          <p class="text-sm opacity-70">
            Takes back what this run made, newest first: the link is turned off, the price and the
            product archived. Stripe deletes none of them (it keeps them for its records), but
            nothing of it can be bought again.
          </p>
          <button
            type="button"
            class="btn btn-error btn-outline btn-sm w-fit"
            phx-click="undo"
            data-confirm="Turn the link off and archive the price and the product?"
            data-testid="sell-undo-submit"
          >
            <.icon name="hero-arrow-uturn-left" class="size-4" /> Undo all of it
          </button>
        </div>
      </section>

      <.steps :if={@undo_steps != []} steps={@undo_steps} title="Undone" testid="sell-undo-steps" />

      <section
        :if={@link}
        class="card bg-success/10 border border-success mt-6"
        data-testid="sell-result"
      >
        <div class="card-body gap-3">
          <.section_title icon="hero-check-circle" title="Your buy link" />
          <a
            href={@link.url}
            target="_blank"
            class="link link-primary text-lg break-all"
            data-testid="sell-link-url"
          >
            {@link.url}
          </a>
          <div class="flex flex-wrap gap-2">
            <a
              href={@link.url}
              target="_blank"
              class="btn btn-primary btn-sm"
              data-testid="sell-link-open"
            >
              Open it as a buyer <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            </a>
          </div>
          <form
            phx-submit="buyer_url"
            class="flex flex-wrap items-end gap-2"
            data-testid="sell-buyer-form"
          >
            <.field
              name="reference"
              label="One buyer's order or user id"
              placeholder="order-42"
              testid="sell-buyer-reference"
            />
            <.field name="email" label="Their email" type="email" testid="sell-buyer-email" />
            <button class="btn btn-sm" data-testid="sell-buyer-submit">Make their address</button>
          </form>
          <a
            :if={@buyer_url}
            href={@buyer_url}
            target="_blank"
            class="link text-xs break-all"
            data-testid="sell-buyer-url"
          >
            {@buyer_url}
          </a>
          <p class="text-sm opacity-70">
            Buyers pay on Stripe's page and come back to the shop; their payments show on the home
            page like any other. Manage the link under Payment links there.
          </p>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :steps, :list, required: true
  attr :title, :string, required: true
  attr :testid, :string, required: true

  defp steps(assigns) do
    ~H"""
    <section class="card bg-base-200 mt-6" data-testid={@testid}>
      <div class="card-body">
        <.section_title icon="hero-queue-list" title={@title} />
        <ol class="space-y-3">
          <li :for={step <- @steps} class="flex gap-3" data-testid="sell-step" data-state={step.state}>
            <span class={["badge", step_class(step.state)]}>{step.n}</span>
            <div class="min-w-0 flex-1">
              <div class="font-medium">
                {step.title}
                <span :if={step.state == :running} class="loading loading-dots loading-xs"></span>
                <span :if={step.ms} class="text-xs opacity-60">{step.ms} ms</span>
              </div>
              <code class="text-xs opacity-60">{step.call}</code>
              <div
                :if={step.detail}
                class={["text-sm break-all", step.state == :failed && "text-error"]}
                data-testid="sell-step-detail"
              >
                {step.detail}
              </div>
            </div>
          </li>
        </ol>
      </div>
    </section>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :testid, :string, required: true
  attr :type, :string, default: "text"
  attr :params, :map, default: %{}
  attr :rest, :global, include: ~w(required placeholder step min max)

  defp field(assigns) do
    ~H"""
    <label class="fieldset">
      <span class="fieldset-legend">{@label}</span>
      <input
        name={@name}
        type={@type}
        value={@params[@name]}
        class="input input-sm"
        data-testid={@testid}
        {@rest}
      />
    </label>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :testid, :string, required: true
  attr :options, :list, required: true
  attr :params, :map, default: %{}

  defp choice(assigns) do
    ~H"""
    <label class="fieldset">
      <span class="fieldset-legend">{@label}</span>
      <select name={@name} class="select select-sm" data-testid={@testid}>
        <option
          :for={{value, label} <- @options}
          value={value}
          selected={(@params[@name] || "") == value}
        >
          {label}
        </option>
      </select>
    </label>
    """
  end

  defp step_class(:running), do: "badge-info"
  defp step_class(:done), do: "badge-success"
  defp step_class(:failed), do: "badge-error"

  defp metadata(params) do
    case {present(params["meta_key"]), present(params["meta_value"])} do
      {key, value} when is_binary(key) and is_binary(value) -> %{key => value}
      _none -> nil
    end
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

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

  defp checked("true"), do: true
  defp checked(_unchecked), do: nil

  defp on_off("on"), do: true
  defp on_off("off"), do: false
  defp on_off(_default), do: nil
end

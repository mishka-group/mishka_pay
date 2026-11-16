defmodule ShopWeb.PayComponents do
  @moduledoc """
  The demo shop's pieces of page, each showing one part of Mishka Pay. Every part a test reads or
  presses carries a `data-testid`, so a browser test finds it without leaning on text or layout.
  """

  use Phoenix.Component

  import ShopWeb.CoreComponents, only: [icon: 1]

  attr :icon, :string, required: true
  attr :title, :string, required: true

  def section_title(assigns) do
    ~H"""
    <h2 class="text-lg font-semibold mb-3 flex items-center gap-2">
      <.icon name={@icon} class="size-5 opacity-70" /> {@title}
    </h2>
    """
  end

  @doc "A small muted code hint under a heading: the Mishka Pay name behind what is shown."
  slot :inner_block, required: true

  def hint(assigns) do
    ~H"""
    <p class="text-xs opacity-60 mb-2" data-testid="code-hint">
      <code>{render_slot(@inner_block)}</code>
    </p>
    """
  end

  @doc "What Mishka Pay sees right now: providers, the site's keys and settings, and plugins."
  attr :providers, :list, required: true
  attr :keys, :any, required: true
  attr :setting, :any, required: true
  attr :tenant, :string, required: true
  attr :plugins, :list, required: true
  attr :local_webhook_secret?, :boolean, required: true
  attr :paypal?, :boolean, default: false

  def status(assigns) do
    ~H"""
    <section class="grid gap-4 lg:grid-cols-3" data-testid="status">
      <div class="card bg-base-200" data-testid="providers">
        <div class="card-body gap-2">
          <h2 class="card-title text-base">
            <.icon name="hero-puzzle-piece" class="size-5" /> Providers
          </h2>
          <div
            :for={provider <- @providers}
            class="flex flex-wrap items-center gap-2"
            data-testid={"provider-#{provider.id()}"}
          >
            <span class="font-medium">{provider.label()}</span>
            <code class="text-xs opacity-70">{provider.id()}</code>
            <span :for={capability <- provider.capabilities()} class="badge badge-primary badge-sm">
              {capability}
            </span>
          </div>
          <p :if={@providers == []} class="text-sm opacity-70">None installed.</p>
        </div>
      </div>

      <div class="card bg-base-200" data-testid="site">
        <div class="card-body gap-2">
          <h2 class="card-title text-base">
            <.icon name="hero-key" class="size-5" /> Site
          </h2>
          <.hint>tenant {@tenant}</.hint>
          <div :if={!@keys} role="alert" class="alert alert-warning py-2" data-testid="site-no-keys">
            No keys: put <code>STRIPE_SECRET_KEY</code> in <code>examples/shop/.env</code>.
          </div>
          <dl :if={@keys} class="grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
            <dt class="opacity-70">Mode</dt>
            <dd data-testid="site-mode">
              <span class="badge badge-warning badge-sm">{@keys.mode}</span>
            </dd>
            <dt class="opacity-70">Secret key</dt>
            <dd>set (never shown)</dd>
            <dt class="opacity-70">Webhook secret</dt>
            <dd data-testid="site-webhook-secret">
              {if @local_webhook_secret?, do: "the simulator's own", else: "from stripe listen"}
            </dd>
            <dt class="opacity-70">Refunds</dt>
            <dd data-testid="site-refunds">{@keys.refunds}</dd>
            <dt class="opacity-70">Merchant of record</dt>
            <dd data-testid="site-merchant">{on_off(@keys.merchant_of_record)}</dd>
            <dt class="opacity-70">Shop</dt>
            <dd data-testid="site-open">
              <span class={["badge badge-sm", (@setting.open && "badge-success") || "badge-error"]}>
                {if @setting.open, do: "open", else: "closed"}
              </span>
            </dd>
            <dt class="opacity-70">PayPal</dt>
            <dd data-testid="site-paypal">coming soon</dd>
          </dl>
        </div>
      </div>

      <div class="card bg-base-200" data-testid="plugins">
        <div class="card-body gap-2">
          <h2 class="card-title text-base">
            <.icon name="hero-bolt" class="size-5" /> Plugins on Mishka Pay's events
          </h2>
          <.hint>mishka_pay:* events</.hint>
          <ul class="text-xs space-y-1">
            <li :for={plugin <- @plugins} class="flex flex-wrap gap-1" data-testid="plugin">
              <code class="opacity-70">{plugin.event}</code>
              <span class="font-medium">{inspect(plugin.name)}</span>
              <span class="badge badge-ghost badge-xs">{plugin.status}</span>
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  attr :product, :map, required: true
  attr :open?, :boolean, required: true

  def product(assigns) do
    ~H"""
    <div class="card bg-base-200" data-testid={"product-#{@product.slug}"}>
      <div class="card-body">
        <.icon name={@product.icon} class="size-8 text-primary" />
        <h3 class="card-title">{@product.name}</h3>
        <p class="text-2xl font-semibold" data-testid="product-price">
          ${@product.price}
          <span :if={@product.interval} class="text-base font-normal">
            / {if @product.interval_count > 1,
              do: "#{@product.interval_count} #{@product.interval}s",
              else: @product.interval}
          </span>
          <span class="text-sm font-normal opacity-60">+ tax</span>
        </p>
        <span :if={@product.trial_days} class="badge badge-info badge-sm" data-testid="product-trial">
          {@product.trial_days}-day free trial
        </span>
        <button
          name="product"
          value={@product.slug}
          class="btn btn-primary"
          phx-disable-with="Opening Stripe..."
          data-testid={"buy-#{@product.slug}"}
        >
          {if @product.interval, do: "Subscribe with Stripe", else: "Buy with Stripe"}
        </button>
        <p :if={!@open?} class="text-xs text-error">The shop is closed: the gate will refuse.</p>
      </div>
    </div>
    """
  end

  @doc "The optional parts of a checkout, sent with whichever product is bought."
  attr :max_quantity, :integer, required: true
  attr :paypal?, :boolean, default: false

  def checkout_options(assigns) do
    ~H"""
    <details class="collapse collapse-arrow bg-base-200" data-testid="checkout-options">
      <summary class="collapse-title font-medium">
        Checkout options
        <span class="text-sm opacity-60">
          (provider, quantity, buyer, merchant of record, metadata)
        </span>
      </summary>
      <div class="collapse-content grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <label class="fieldset">
          <span class="fieldset-legend">Pay with</span>
          <select name="provider" class="select select-sm" data-testid="option-provider">
            <option value="stripe">Stripe</option>
            <option value="paypal" disabled>PayPal (coming soon)</option>
          </select>
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">Quantity, 1 to {@max_quantity}</span>
          <input
            name="quantity"
            type="number"
            min="1"
            max={@max_quantity}
            step="1"
            value="1"
            class="input input-sm"
            data-testid="option-quantity"
          />
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">Buyer email</span>
          <input
            name="email"
            type="email"
            placeholder="filled on Stripe's page"
            class="input input-sm"
            data-testid="option-email"
          />
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">Merchant of record, this checkout</span>
          <select name="merchant_of_record" class="select select-sm" data-testid="option-merchant">
            <option value="">The site's setting</option>
            <option value="on">On</option>
            <option value="off">Off</option>
          </select>
        </label>
        <div class="fieldset">
          <span class="fieldset-legend">Metadata</span>
          <div class="join">
            <input
              name="meta_key"
              placeholder="key"
              class="input input-sm join-item w-24"
              data-testid="option-meta-key"
            />
            <input
              name="meta_value"
              placeholder="value"
              class="input input-sm join-item w-28"
              data-testid="option-meta-value"
            />
          </div>
        </div>
      </div>
    </details>
    """
  end

  @doc "Stripe's test cards, each with what it does."
  def test_cards(assigns) do
    ~H"""
    <details class="mt-3 text-sm" data-testid="test-cards">
      <summary class="cursor-pointer opacity-80">
        Test cards (any future date, any CVC). Prices are before tax: Stripe adds it at checkout.
      </summary>
      <div class="overflow-x-auto mt-2">
        <table class="table table-xs">
          <tbody>
            <tr :for={{card, what} <- test_card_list()}>
              <td><code>{card}</code></td>
              <td>{what}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </details>
    """
  end

  defp test_card_list do
    [
      {"5555 5555 5555 4444", "Mastercard, pays"},
      {"4242 4242 4242 4242", "Visa, pays (blocked after a refund marked fraudulent)"},
      {"3782 822463 10005", "American Express, pays"},
      {"4000 0025 0000 3155", "asks for 3D Secure, then pays"},
      {"4000 0000 0000 0002", "declined"},
      {"4000 0000 0000 9995", "declined, insufficient funds"},
      {"4000 0000 0000 0069", "declined, expired card"},
      {"4000 0000 0000 0127", "declined, wrong CVC"}
    ]
  end

  attr :payment, :map, required: true
  attr :names, :map, required: true

  def last_bought(assigns) do
    ~H"""
    <section class="card bg-base-200 border border-success/40" data-testid="last-bought">
      <div class="card-body flex-row flex-wrap items-center gap-4">
        <.icon name="hero-shopping-bag" class="size-8 text-success" />
        <div class="flex-1 min-w-48">
          <p class="text-sm opacity-70">Last bought</p>
          <p class="text-lg font-semibold">
            {product_name(@payment.reference, @names)} · {money(@payment.amount, @payment.currency)}
          </p>
          <p class="text-xs opacity-60">
            {bought_by(@payment)}
          </p>
        </div>
        <.status_badge status={@payment.status} />
        <button
          class="btn btn-sm"
          phx-click="select"
          phx-value-id={@payment.id}
          data-testid="last-bought-details"
        >
          Details
        </button>
      </div>
    </section>
    """
  end

  defp bought_by(payment) do
    case payment.customer_name || payment.customer_email do
      nil -> "Paid, tax included. The buyer is not known yet."
      buyer -> "#{buyer} paid this, tax included."
    end
  end

  @doc "How many payments each status has, and their money; a status filters the table."
  attr :stats, :list, required: true
  attr :filter, :string, required: true
  attr :statuses, :list, required: true

  def stats(assigns) do
    assigns =
      assign(assigns,
        by_status: Map.new(assigns.stats, &{&1.status, &1}),
        count: Enum.sum_by(assigns.stats, & &1.count),
        taken: total(assigns.stats, ["paid", "partially_refunded", "refunded"], :amount),
        refunded: total(assigns.stats, ["partially_refunded", "refunded"], :refunded)
      )

    ~H"""
    <div class="mb-3 space-y-2" data-testid="stats">
      <div class="flex flex-wrap gap-4 text-sm">
        <span data-testid="stats-count"><b>{@count}</b> payments</span>
        <span data-testid="stats-taken">taken <b>{money(@taken, "USD")}</b></span>
        <span data-testid="stats-refunded">refunded <b>{money(@refunded, "USD")}</b></span>
      </div>
      <form phx-change="filter" class="flex flex-wrap gap-1" data-testid="status-filter">
        <label
          :for={status <- ["all" | @statuses]}
          class={["btn btn-xs", (@filter == status && "btn-primary") || "btn-ghost"]}
          data-testid={"filter-#{status}"}
        >
          <input type="radio" name="status" value={status} class="hidden" checked={@filter == status} />
          {status}
          <span class="badge badge-xs">
            {if status == "all", do: @count, else: (@by_status[status] || %{count: 0}).count}
          </span>
        </label>
      </form>
    </div>
    """
  end

  defp total(stats, statuses, key) do
    stats
    |> Enum.filter(&(&1.status in statuses))
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, Map.fetch!(&1, key) || 0))
  end

  attr :payments, :any, required: true
  attr :names, :map, required: true

  def payments_table(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-box border border-base-300">
      <table class="table">
        <thead>
          <tr>
            <th>Product</th>
            <th>Buyer</th>
            <th>Card</th>
            <th>Amount</th>
            <th>Refunded</th>
            <th>Status</th>
            <th>Synced</th>
          </tr>
        </thead>
        <tbody id="payments" phx-update="stream" data-testid="payments-rows">
          <tr id="payments-empty" class="only:table-row hidden" data-testid="payments-empty">
            <td colspan="7" class="text-center opacity-70">No payments here yet.</td>
          </tr>
          <tr
            :for={{dom_id, payment} <- @payments}
            id={dom_id}
            class="hover:bg-base-200 cursor-pointer"
            phx-click="select"
            phx-value-id={payment.id}
            data-testid="payment-row"
            data-payment-id={payment.provider_id}
            data-status={payment.status}
          >
            <td>
              <div class="font-medium flex items-center gap-2">
                {product_name(payment.reference, @names)}
                <.provider_badge provider={payment.provider} />
              </div>
              <div class="text-xs opacity-60 font-mono">{payment.provider_id}</div>
            </td>
            <td class="text-sm">
              <div>{payment.customer_name || "–"}</div>
              <div class="text-xs opacity-60">{payment.customer_email}</div>
            </td>
            <td class="text-sm">{card(payment.card_brand, payment.card_last4)}</td>
            <td>{money(payment.amount, payment.currency)}</td>
            <td>{money(payment.amount_refunded, payment.currency)}</td>
            <td>
              <.status_badge status={payment.status} />
              <div :if={payment.failure_message} class="text-xs text-error max-w-48">
                {payment.failure_message}
              </div>
            </td>
            <td class="text-xs opacity-70">{time(payment.synced_at)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc "One payment: the row the shop keeps, the payment as Stripe has it, its events and actions."
  attr :selected, :map, required: true
  attr :live, :any, required: true
  attr :names, :map, required: true

  def payment_details(assigns) do
    ~H"""
    <section
      id="payment-details"
      class="card bg-base-200 border border-primary/40"
      data-testid="payment-details"
      data-payment-id={@selected.payment.provider_id}
    >
      <div class="card-body gap-4">
        <div class="flex flex-wrap items-center gap-3">
          <h2 class="card-title flex-1 min-w-0 flex-wrap">
            {product_name(@selected.payment.reference, @names)}
            <.provider_badge provider={@selected.payment.provider} />
            <code class="text-sm opacity-70 break-all">{@selected.payment.provider_id}</code>
          </h2>
          <a
            :if={@selected.payment.provider == "stripe"}
            href={"https://dashboard.stripe.com/test/payments/#{@selected.payment.provider_id}"}
            target="_blank"
            class="btn btn-ghost btn-sm shrink-0"
            data-testid="details-stripe-link"
          >
            Stripe <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </a>
          <button
            class="btn btn-ghost btn-sm shrink-0"
            phx-click="close"
            aria-label="Close"
            data-testid="details-close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <div class="rounded-box bg-base-100 p-4" data-testid="details-stored">
            <h3 class="font-medium">In the shop's database</h3>
            <.hint>Shop.Pay.Payment</.hint>
            <dl class="grid grid-cols-2 gap-y-1 text-sm">
              <dt class="opacity-70">Status</dt>
              <dd data-testid="stored-status"><.status_badge status={@selected.payment.status} /></dd>
              <dt class="opacity-70">Money</dt>
              <dd data-testid="stored-amount">{Money.to_string!(@selected.payment.money)}</dd>
              <dt class="opacity-70">Refunded</dt>
              <dd data-testid="stored-refunded">
                {Money.to_string!(@selected.payment.money_refunded)}
              </dd>
              <dt class="opacity-70">Buyer</dt>
              <dd data-testid="stored-buyer">
                {@selected.payment.customer_name || "–"}
                <span class="block text-xs opacity-70">{@selected.payment.customer_email}</span>
              </dd>
              <dt class="opacity-70">Card</dt>
              <dd data-testid="stored-card">
                {card(@selected.payment.card_brand, @selected.payment.card_last4)}
              </dd>
              <dt :if={@selected.payment.failure_message} class="opacity-70">Failed because</dt>
              <dd
                :if={@selected.payment.failure_message}
                class="text-error"
                data-testid="stored-failure"
              >
                <.failure message={@selected.payment.failure_message} />
              </dd>
              <dt class="opacity-70">Reference</dt>
              <dd class="font-mono text-xs break-all">{@selected.payment.reference}</dd>
              <dt class="opacity-70">Customer</dt>
              <dd class="font-mono text-xs">{@selected.payment.customer_id || "none"}</dd>
              <dt class="opacity-70">Site</dt>
              <dd>{@selected.payment.tenant}</dd>
              <dt class="opacity-70">Made at Stripe</dt>
              <dd class="text-xs">{time(@selected.payment.provider_created_at)}</dd>
              <dt class="opacity-70">Last synced</dt>
              <dd class="text-xs" data-testid="stored-synced">{time(@selected.payment.synced_at)}</dd>
            </dl>
            <button
              class="btn btn-sm mt-3"
              phx-click="sync"
              phx-value-payment_id={@selected.payment.provider_id}
              data-testid="details-sync"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Sync from Stripe
            </button>
          </div>

          <div class="rounded-box bg-base-100 p-4" data-testid="details-live">
            <h3 class="font-medium">Live from Stripe</h3>
            <.hint>MishkaPay.fetch_payment/3</.hint>
            <.async_result :let={live} assign={@live}>
              <:loading>
                <span class="loading loading-dots loading-sm"></span> Asking Stripe...
              </:loading>
              <:failed :let={{:error, reason}}>
                <span class="text-error text-sm" data-testid="live-error">{reason}</span>
              </:failed>
              <dl class="grid grid-cols-2 gap-y-1 text-sm">
                <dt class="opacity-70">Status</dt>
                <dd data-testid="live-status"><.status_badge status={live.status} /></dd>
                <dt class="opacity-70">Amount</dt>
                <dd data-testid="live-amount">{Money.to_string!(live.amount)}</dd>
                <dt class="opacity-70">Refunded</dt>
                <dd data-testid="live-refunded">{Money.to_string!(live.amount_refunded)}</dd>
                <dt class="opacity-70">Buyer</dt>
                <dd data-testid="live-buyer">
                  {live.customer_name || "–"}
                  <span class="block text-xs opacity-70">{live.customer_email}</span>
                </dd>
                <dt class="opacity-70">Paid with</dt>
                <dd data-testid="live-card">
                  {paid_with(live.payment_method, live.card_brand, live.card_last4)}
                </dd>
                <dt :if={live.failure_message} class="opacity-70">Failed because</dt>
                <dd :if={live.failure_message} class="text-error" data-testid="live-failure">
                  <.failure message={live.failure_message} code={live.failure_code} />
                </dd>
                <dt class="opacity-70">Description</dt>
                <dd>{live.description || "–"}</dd>
                <dt class="opacity-70">Metadata</dt>
                <dd class="text-xs" data-testid="live-metadata">
                  <span :if={live.metadata in [nil, %{}]}>none</span>
                  <span :for={{key, value} <- live.metadata || %{}} class="block">
                    <code>{key}</code> = {value}
                  </span>
                </dd>
                <dt class="opacity-70">Receipt</dt>
                <dd>
                  <a
                    :if={live.receipt_url}
                    href={live.receipt_url}
                    target="_blank"
                    class="link"
                    data-testid="live-receipt"
                  >
                    Open receipt
                  </a>
                  <span :if={!live.receipt_url}>–</span>
                </dd>
                <dt class="opacity-70">Created</dt>
                <dd class="text-xs">{time(live.created_at)}</dd>
              </dl>
              <div class="mt-3" data-testid="live-refunds">
                <h4 class="text-sm font-medium">Refunds ({length(live.refunds)})</h4>
                <ul class="text-xs space-y-1 mt-1">
                  <li
                    :for={refund <- live.refunds}
                    class="flex flex-wrap gap-2"
                    data-testid="live-refund"
                  >
                    <code>{refund.id}</code>
                    <span>{Money.to_string!(refund.amount)}</span>
                    <span class="badge badge-xs">{refund.status}</span>
                    <span :if={refund.reason} class="opacity-70">{refund.reason}</span>
                    <span class="opacity-60">{time(refund.created_at)}</span>
                  </li>
                </ul>
              </div>
            </.async_result>
          </div>
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <div
            :if={@selected.payment.status not in [:paid, :partially_refunded]}
            class="rounded-box bg-base-100 p-4"
            data-testid="refund-unavailable"
          >
            <h3 class="font-medium">Refund</h3>
            <.hint>:refund action</.hint>
            <p class="text-sm opacity-70">{no_refund(@selected.payment.status)}</p>
            <div :if={@selected.refund} class="text-sm mt-2" data-testid="last-refund">
              <span class="opacity-70">Last refund:</span>
              <code>{@selected.refund.id}</code>
              · {Money.to_string!(@selected.refund.amount)} · {@selected.refund.status}
            </div>
          </div>
          <form
            :if={@selected.payment.status in [:paid, :partially_refunded]}
            phx-submit="refund"
            novalidate
            class="rounded-box bg-base-100 p-4 space-y-2"
            data-testid="refund-form"
          >
            <h3 class="font-medium">Refund</h3>
            <.hint>:refund action</.hint>
            <input type="hidden" name="payment" value={@selected.payment.id} />
            <div class="flex flex-wrap gap-2">
              <input
                name="amount"
                type="number"
                step="0.01"
                min="0.01"
                placeholder="amount, empty = all"
                class="input input-sm w-44"
                data-testid="refund-amount"
              />
              <select name="reason" class="select select-sm w-60" data-testid="refund-reason">
                <option value="">No reason</option>
                <option value="requested_by_customer">Requested by customer</option>
                <option value="duplicate">Duplicate</option>
                <option value="fraudulent">Fraudulent (Stripe then blocks this card)</option>
              </select>
              <button
                class="btn btn-sm btn-warning"
                phx-disable-with="Refunding..."
                data-testid="refund-submit"
              >
                Refund
              </button>
            </div>
            <div :if={@selected.refund} class="text-sm" data-testid="last-refund">
              <span class="opacity-70">Last refund:</span>
              <code>{@selected.refund.id}</code>
              · {Money.to_string!(@selected.refund.amount)} · {@selected.refund.status}
            </div>
          </form>

          <div class="rounded-box bg-base-100 p-4" data-testid="details-events">
            <h3 class="font-medium mb-2">Webhook events about it</h3>
            <p :if={@selected.events == []} class="text-sm opacity-70">
              None yet. Send one with the webhook simulator below.
            </p>
            <ul class="text-sm space-y-1">
              <li
                :for={event <- @selected.events}
                class="flex flex-wrap gap-2"
                data-testid="details-event"
              >
                <code>{event.type}</code>
                <span class="badge badge-sm">{event.status}</span>
                <span :if={event.last_error} class="text-error text-xs">{event.last_error}</span>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :message, :string, required: true
  attr :code, :string, default: nil

  defp failure(assigns) do
    ~H"""
    {@message} <code :if={@code} class="text-xs opacity-60">{@code}</code>
    """
  end

  defp no_refund(:refunded), do: "Nothing to refund: the payment is refunded in full."
  defp no_refund(:pending), do: "Nothing to refund yet: the payment is not paid."

  defp no_refund(:requires_action),
    do: "Nothing to refund yet: the buyer has not finished paying."

  defp no_refund(:failed), do: "Nothing to refund: the payment failed, no money was taken."

  defp no_refund(:canceled),
    do: "Nothing to refund: the payment was canceled, no money was taken."

  defp no_refund(_other), do: "Nothing to refund on this payment."

  attr :checkout, :map, required: true

  def checkout_card(assigns) do
    ~H"""
    <dl
      class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm mt-3 rounded-box bg-base-200 p-4"
      data-testid="checkout-card"
    >
      <dt class="opacity-70">Checkout</dt>
      <dd class="font-mono text-xs break-all" data-testid="checkout-id">{@checkout.id}</dd>
      <dt class="opacity-70">Status</dt>
      <dd data-testid="checkout-status"><span class="badge badge-sm">{@checkout.status}</span></dd>
      <dt class="opacity-70">Total</dt>
      <dd data-testid="checkout-total">
        {(@checkout.amount_total && Money.to_string!(@checkout.amount_total)) || "–"}
      </dd>
      <dt class="opacity-70">Tax in it</dt>
      <dd data-testid="checkout-tax">
        {(@checkout.amount_tax && Money.to_string!(@checkout.amount_tax)) || "–"}
      </dd>
      <dt class="opacity-70">Buyer email</dt>
      <dd data-testid="checkout-email">{(@checkout.customer && @checkout.customer.email) || "–"}</dd>
      <dt class="opacity-70">Payment</dt>
      <dd class="font-mono text-xs" data-testid="checkout-payment">
        {@checkout.payment_id || "none yet"}
      </dd>
      <dt class="opacity-70">Reference</dt>
      <dd class="font-mono text-xs break-all">{@checkout.reference}</dd>
    </dl>
    """
  end

  @doc "Sends a signed Stripe webhook about a payment to the shop's own endpoint."
  attr :types, :list, required: true
  attr :simulated, :any, required: true
  attr :situations, :list, required: true
  attr :form, :map, default: %{}
  attr :tenant, :string, required: true
  attr :local_webhook_secret?, :boolean, required: true

  def webhook_simulator(assigns) do
    ~H"""
    <section data-testid="webhook-simulator">
      <.section_title icon="hero-paper-airplane" title="Webhook simulator" />
      <p class="text-sm opacity-70 mb-2">
        Sends a Stripe event about a payment to <code>/pay/webhooks/stripe/{@tenant}</code>,
        signed as Stripe signs. It goes the whole way: signature check, inbox, job, payment sync. PayPal webhooks cannot be simulated here: PayPal checks each one itself, on its servers.
        <span :if={!@local_webhook_secret?}>
          Signed with your <code>STRIPE_WEBHOOK_SECRET</code>.
        </span>
        A refused webhook (bad signature) is never stored: it is only counted in telemetry.
      </p>
      <form phx-submit="simulate" class="flex flex-wrap gap-2 items-end">
        <input
          name="payment_id"
          placeholder="pi_... or sub_... (copy it from a row)"
          class="input input-sm w-72"
          value={@form[:payment_id]}
          data-testid="simulate-payment"
        />
        <select name="type" class="select select-sm" data-testid="simulate-type">
          <option :for={type <- @types} value={type} selected={type == @form[:type]}>
            {type}
          </option>
        </select>
        <select name="situation" class="select select-sm" data-testid="simulate-situation">
          <option
            :for={{name, spec} <- @situations}
            value={name}
            selected={Atom.to_string(name) == @form[:situation]}
          >
            {spec.label}
          </option>
        </select>
        <button class="btn btn-sm" data-testid="simulate-submit">Send webhook</button>
      </form>
      <div
        :if={@simulated}
        class="mt-2 text-sm flex flex-wrap items-center gap-2"
        data-testid="simulate-result"
        data-statuses={Enum.join(@simulated.statuses, ",")}
        data-expected={Enum.join(@simulated.expect, ",")}
        data-pass={to_string(@simulated.statuses == @simulated.expect)}
      >
        <span class={[
          "badge badge-sm",
          (@simulated.statuses == @simulated.expect && "badge-success") || "badge-error"
        ]}>
          {if @simulated.statuses == @simulated.expect, do: "as expected", else: "NOT as expected"}
        </span>
        <span>{@simulated.label}:</span>
        <span>HTTP {Enum.join(@simulated.statuses, " then ")}</span>
        <span class="opacity-60">(expected {Enum.join(@simulated.expect, " then ")})</span>
        <code class="text-xs opacity-70">{@simulated.event_id}</code>
        <span class="opacity-70 basis-full">{simulated_meaning(@simulated.situation)}</span>
      </div>
    </section>
    """
  end

  defp simulated_meaning(:good),
    do:
      "Stored once in the inbox and worked as a job: the row shows processed, or the error once its tries run out."

  defp simulated_meaning(:bad_signature),
    do: "Refused and never stored: the signature does not match the site's secret."

  defp simulated_meaning(:old_timestamp),
    do: "Refused: a signature older than 5 minutes is a replay, even when it is real."

  defp simulated_meaning(:unknown_tenant),
    do: "Refused the same way as a bad signature, so a stranger cannot tell which sites exist."

  defp simulated_meaning(:unknown_provider), do: "No such provider installed: 404."
  defp simulated_meaning(:wrong_method), do: "The endpoint takes POST only: 405."

  defp simulated_meaning(:too_large),
    do: "Refused before reading on: a webhook body is never over 1 MB."

  defp simulated_meaning(:listener_fails),
    do:
      "A listener could not take it: 500, so Stripe sends it again later. The inbox still kept it."

  defp simulated_meaning(:twice),
    do: "Both are answered 200, and the inbox keeps it once: a provider may send an event twice."

  attr :events, :any, required: true

  def inbox_table(assigns) do
    ~H"""
    <p class="text-sm opacity-70 mb-2">
      Every checked webhook, stored once and worked as a job. Real Stripe events come with <code>stripe listen</code>; the simulator above sends test ones.
    </p>
    <div class="overflow-auto rounded-box border border-base-300 max-h-80">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>Type</th>
            <th>About</th>
            <th>Status</th>
            <th>Error</th>
          </tr>
        </thead>
        <tbody id="inbox" phx-update="stream" data-testid="inbox-rows">
          <tr id="inbox-empty" class="only:table-row hidden">
            <td colspan="4" class="text-center opacity-70">No webhook events yet.</td>
          </tr>
          <tr
            :for={{dom_id, event} <- @events}
            id={dom_id}
            data-testid="inbox-row"
            data-event-id={event.event_id}
            data-status={event.status}
          >
            <td><code class="text-xs">{event.type}</code></td>
            <td class="font-mono text-xs break-all">{event.payment_id || event.subscription_id}</td>
            <td><span class="badge badge-sm">{event.status}</span></td>
            <td class="text-xs text-error">{event.last_error}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :entries, :any, required: true

  def telemetry_log(assigns) do
    ~H"""
    <p class="text-sm opacity-70 mb-2">Every Mishka Pay call and HTTP request, as it happens.</p>
    <div class="overflow-auto rounded-box border border-base-300 max-h-80">
      <table class="table table-sm table-fixed">
        <thead>
          <tr>
            <th class="w-28">Event</th>
            <th>What</th>
            <th class="w-24">Outcome</th>
            <th class="w-14">ms</th>
          </tr>
        </thead>
        <tbody id="telemetry" phx-update="stream" data-testid="telemetry-rows">
          <tr id="telemetry-empty" class="only:table-row hidden">
            <td colspan="4" class="text-center opacity-70">Nothing yet. Buy, sync or refund.</td>
          </tr>
          <tr
            :for={{dom_id, entry} <- @entries}
            id={dom_id}
            data-testid="telemetry-row"
            data-event={entry.event}
          >
            <td><code class="text-xs">{entry.event}</code></td>
            <td class="text-xs break-all">{entry.detail}</td>
            <td><span class="badge badge-sm">{entry.outcome}</span></td>
            <td class="text-xs">{entry.ms}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :setting, :any, required: true
  attr :tenant, :string, required: true

  def settings_form(assigns) do
    ~H"""
    <section class="card bg-base-200" data-testid="settings">
      <form phx-submit="save_settings" class="card-body gap-4">
        <div>
          <h2 class="card-title">
            <.icon name="hero-cog-6-tooth" class="size-5" /> Site settings
          </h2>
          <p class="text-sm opacity-70">
            Kept in the database for the site <code>{@tenant}</code>
            and read by Mishka Pay on every call. In a multi-site project each site has its own.
          </p>
        </div>

        <div class="grid gap-4 md:grid-cols-3">
          <fieldset class="fieldset">
            <legend class="fieldset-legend">Refunds</legend>
            <label class="label">
              <input
                type="radio"
                name="refunds"
                value="once"
                class="radio radio-sm"
                checked={@setting.refunds == :once}
                data-testid="setting-refunds-once"
              /> Once per payment
            </label>
            <label class="label">
              <input
                type="radio"
                name="refunds"
                value="many"
                class="radio radio-sm"
                checked={@setting.refunds == :many}
                data-testid="setting-refunds-many"
              /> Many part refunds
            </label>
          </fieldset>

          <fieldset class="fieldset">
            <legend class="fieldset-legend">Merchant of record</legend>
            <select name="merchant_of_record" class="select select-sm" data-testid="setting-merchant">
              <option value="" selected={is_nil(@setting.merchant_of_record)}>
                Stripe account default
              </option>
              <option value="on" selected={@setting.merchant_of_record == true}>On</option>
              <option value="off" selected={@setting.merchant_of_record == false}>Off</option>
            </select>
          </fieldset>

          <fieldset class="fieldset">
            <legend class="fieldset-legend">Checkout gate</legend>
            <label class="label">
              <input
                type="radio"
                name="open"
                value="true"
                class="radio radio-sm"
                checked={@setting.open}
                data-testid="setting-open"
              /> Shop open
            </label>
            <label class="label">
              <input
                type="radio"
                name="open"
                value="false"
                class="radio radio-sm"
                checked={!@setting.open}
                data-testid="setting-closed"
              /> Closed: every checkout is refused
            </label>
          </fieldset>
        </div>

        <div><button class="btn btn-sm" data-testid="settings-save">Save settings</button></div>
      </form>
    </section>
    """
  end

  @doc "Which provider took a payment."
  attr :provider, :string, required: true

  def provider_badge(assigns) do
    ~H"""
    <span class="badge badge-outline badge-xs" data-testid="provider-badge">{@provider}</span>
    """
  end

  attr :status, :atom, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", status_class(@status)]} data-testid="status-badge">{@status}</span>
    """
  end

  defp product_name(reference, names), do: Shop.Catalog.name_of(reference, names)

  defp money(amount, currency), do: currency |> Money.new(amount || 0) |> Money.to_string!()

  defp paid_with(method, brand, last4) do
    case Enum.reject([method, brand && card(brand, last4)], &is_nil/1) do
      [] -> "–"
      parts -> Enum.join(parts, " ")
    end
  end

  defp card(nil, _last4), do: "–"
  defp card(brand, last4), do: "#{brand} •••• #{last4}"

  defp time(nil), do: "–"
  defp time(%DateTime{} = time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M:%S")

  defp on_off(true), do: "on"
  defp on_off(false), do: "off"
  defp on_off(nil), do: "account default"

  defp status_class(:paid), do: "badge-success"
  defp status_class(:refunded), do: "badge-neutral"
  defp status_class(:partially_refunded), do: "badge-info"
  defp status_class(status) when status in [:failed, :canceled], do: "badge-error"
  defp status_class(_waiting), do: "badge-warning"
end

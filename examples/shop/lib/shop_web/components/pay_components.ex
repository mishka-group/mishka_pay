defmodule ShopWeb.PayComponents do
  @moduledoc "The demo shop's pieces of page: each one shows one part of Mishka Pay."

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

  @doc "What Mishka Pay sees right now: installed providers, the site's keys and settings."
  attr :providers, :list, required: true
  attr :keys, :any, required: true
  attr :setting, :any, required: true
  attr :tenant, :string, required: true

  def status(assigns) do
    ~H"""
    <section class="grid gap-4 md:grid-cols-2">
      <div class="card bg-base-200">
        <div class="card-body gap-2">
          <h2 class="card-title text-base">
            <.icon name="hero-puzzle-piece" class="size-5" /> Installed providers
            <span class="badge badge-ghost badge-sm">MishkaPay.Provider.all/0</span>
          </h2>
          <div :for={provider <- @providers} class="flex flex-wrap items-center gap-2">
            <span class="font-medium">{provider.label()}</span>
            <code class="text-xs opacity-70">{provider.id()}</code>
            <span :for={capability <- provider.capabilities()} class="badge badge-primary badge-sm">
              {capability}
            </span>
          </div>
          <p :if={@providers == []} class="text-sm opacity-70">None installed.</p>
        </div>
      </div>

      <div class="card bg-base-200">
        <div class="card-body gap-2">
          <h2 class="card-title text-base">
            <.icon name="hero-key" class="size-5" /> Site <code>{@tenant}</code>
            <span class="badge badge-ghost badge-sm">MishkaPay.Credentials.fetch/2</span>
          </h2>
          <div :if={!@keys} role="alert" class="alert alert-warning py-2">
            No keys: put <code>STRIPE_SECRET_KEY</code> in <code>examples/shop/.env</code>.
          </div>
          <dl :if={@keys} class="grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
            <dt class="opacity-70">Mode</dt>
            <dd><span class="badge badge-warning badge-sm">{@keys.mode}</span></dd>
            <dt class="opacity-70">Secret key</dt>
            <dd>set (never shown)</dd>
            <dt class="opacity-70">Webhook secret</dt>
            <dd>{if @keys.webhook_secret, do: "set", else: "not set (no stripe listen)"}</dd>
            <dt class="opacity-70">Refunds</dt>
            <dd>{@keys.refunds}</dd>
            <dt class="opacity-70">Merchant of record</dt>
            <dd>{on_off(@keys.merchant_of_record)}</dd>
            <dt class="opacity-70">Shop</dt>
            <dd>
              <span class={["badge badge-sm", (@setting.open && "badge-success") || "badge-error"]}>
                {if @setting.open, do: "open", else: "closed"}
              </span>
            </dd>
          </dl>
        </div>
      </div>
    </section>
    """
  end

  attr :product, :map, required: true
  attr :open?, :boolean, required: true

  def product(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <.icon name={@product.icon} class="size-8 text-primary" />
        <h3 class="card-title">{@product.name}</h3>
        <p class="text-2xl font-semibold">
          ${@product.price} <span class="text-xs font-normal opacity-60">+ tax</span>
        </p>
        <button
          name="product"
          value={@product.id}
          class="btn btn-primary"
          phx-disable-with="Opening Stripe..."
        >
          Buy with Stripe
        </button>
        <p :if={!@open?} class="text-xs text-error">The shop is closed: the gate will refuse.</p>
      </div>
    </div>
    """
  end

  @doc "The optional parts of a checkout, sent with whichever product is bought."
  def checkout_options(assigns) do
    ~H"""
    <details class="collapse collapse-arrow bg-base-200">
      <summary class="collapse-title font-medium">
        Checkout options
        <span class="text-sm opacity-60">(quantity, buyer, merchant of record, metadata)</span>
      </summary>
      <div class="collapse-content grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <label class="fieldset">
          <span class="fieldset-legend">Quantity</span>
          <input
            name="quantity"
            type="number"
            min="1"
            max="10"
            step="1"
            value="1"
            class="input input-sm"
          />
          <span class="label text-xs">1 to 10</span>
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">Buyer email</span>
          <input
            name="email"
            type="email"
            placeholder="filled on Stripe's page"
            class="input input-sm"
          />
        </label>
        <label class="fieldset">
          <span class="fieldset-legend">Merchant of record, this checkout</span>
          <select name="merchant_of_record" class="select select-sm">
            <option value="">The site's setting</option>
            <option value="on">On</option>
            <option value="off">Off</option>
          </select>
        </label>
        <div class="fieldset">
          <span class="fieldset-legend">Metadata</span>
          <div class="join">
            <input name="meta_key" placeholder="key" class="input input-sm join-item w-24" />
            <input name="meta_value" placeholder="value" class="input input-sm join-item w-28" />
          </div>
        </div>
      </div>
    </details>
    """
  end

  attr :payment, :map, required: true

  def last_bought(assigns) do
    ~H"""
    <section class="card bg-base-200 border border-success/40">
      <div class="card-body flex-row flex-wrap items-center gap-4">
        <.icon name="hero-shopping-bag" class="size-8 text-success" />
        <div class="flex-1">
          <p class="text-sm opacity-70">Last bought</p>
          <p class="text-lg font-semibold">
            {product_name(@payment.reference)} · {money(@payment.amount, @payment.currency)}
          </p>
          <p class="text-xs opacity-60">What Stripe charged, with the tax it added at checkout.</p>
        </div>
        <.status_badge status={@payment.status} />
        <button class="btn btn-sm" phx-click="select" phx-value-id={@payment.id}>Details</button>
      </div>
    </section>
    """
  end

  attr :payments, :any, required: true

  def payments_table(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-box border border-base-300">
      <table class="table">
        <thead>
          <tr>
            <th>Product</th>
            <th>Amount</th>
            <th>Refunded</th>
            <th>Status</th>
            <th>Synced</th>
            <th></th>
          </tr>
        </thead>
        <tbody id="payments" phx-update="stream">
          <tr id="payments-empty" class="only:table-row hidden">
            <td colspan="6" class="text-center opacity-70">No payments yet. Buy something above.</td>
          </tr>
          <tr
            :for={{dom_id, payment} <- @payments}
            id={dom_id}
            class="hover:bg-base-200 cursor-pointer"
            phx-click="select"
            phx-value-id={payment.id}
          >
            <td>
              <div class="font-medium">{product_name(payment.reference)}</div>
              <div class="text-xs opacity-60 font-mono">{payment.provider_id}</div>
            </td>
            <td>{money(payment.amount, payment.currency)}</td>
            <td>{money(payment.amount_refunded, payment.currency)}</td>
            <td><.status_badge status={payment.status} /></td>
            <td class="text-xs opacity-70">{time(payment.synced_at)}</td>
            <td><span class="btn btn-ghost btn-xs">Details →</span></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc "One payment: the row the shop keeps, the payment as Stripe has it, its events and actions."
  attr :selected, :map, required: true
  attr :live, :any, required: true

  def payment_details(assigns) do
    ~H"""
    <section id="payment-details" class="card bg-base-200 border border-primary/40">
      <div class="card-body gap-4">
        <div class="flex items-center gap-3">
          <h2 class="card-title flex-1 min-w-0 flex-wrap">
            {product_name(@selected.payment.reference)}
            <code class="text-sm opacity-70 break-all">{@selected.payment.provider_id}</code>
          </h2>
          <a
            href={"https://dashboard.stripe.com/test/payments/#{@selected.payment.provider_id}"}
            target="_blank"
            class="btn btn-ghost btn-sm shrink-0"
          >
            Stripe <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </a>
          <button class="btn btn-ghost btn-sm shrink-0" phx-click="close" aria-label="Close">
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <div class="rounded-box bg-base-100 p-4">
            <h3 class="font-medium mb-2">
              In the shop's database <span class="badge badge-ghost badge-sm">Shop.Pay.Payment</span>
            </h3>
            <dl class="grid grid-cols-2 gap-y-1 text-sm">
              <dt class="opacity-70">Status</dt>
              <dd><.status_badge status={@selected.payment.status} /></dd>
              <dt class="opacity-70">Money</dt>
              <dd>{Money.to_string!(@selected.payment.money)}</dd>
              <dt class="opacity-70">Refunded</dt>
              <dd>{Money.to_string!(@selected.payment.money_refunded)}</dd>
              <dt class="opacity-70">Reference</dt>
              <dd class="font-mono text-xs break-all">{@selected.payment.reference}</dd>
              <dt class="opacity-70">Customer</dt>
              <dd class="font-mono text-xs">{@selected.payment.customer_id || "none"}</dd>
              <dt class="opacity-70">Site</dt>
              <dd>{@selected.payment.tenant}</dd>
              <dt class="opacity-70">Paid at Stripe</dt>
              <dd class="text-xs">{time(@selected.payment.provider_created_at)}</dd>
              <dt class="opacity-70">Last synced</dt>
              <dd class="text-xs">{time(@selected.payment.synced_at)}</dd>
            </dl>
            <button
              class="btn btn-sm mt-3"
              phx-click="sync"
              phx-value-payment_id={@selected.payment.provider_id}
            >
              <.icon name="hero-arrow-path" class="size-4" /> Sync from Stripe
            </button>
          </div>

          <div class="rounded-box bg-base-100 p-4">
            <h3 class="font-medium mb-2">
              Live from Stripe
              <span class="badge badge-ghost badge-sm">MishkaPay.fetch_payment/3</span>
            </h3>
            <.async_result :let={live} assign={@live}>
              <:loading>
                <span class="loading loading-dots loading-sm"></span> Asking Stripe...
              </:loading>
              <:failed :let={{:error, reason}}>
                <span class="text-error text-sm">{reason}</span>
              </:failed>
              <dl class="grid grid-cols-2 gap-y-1 text-sm">
                <dt class="opacity-70">Status</dt>
                <dd><.status_badge status={live.status} /></dd>
                <dt class="opacity-70">Amount</dt>
                <dd>{Money.to_string!(live.amount)}</dd>
                <dt class="opacity-70">Refunded</dt>
                <dd>{Money.to_string!(live.amount_refunded)}</dd>
                <dt class="opacity-70">Reference</dt>
                <dd class="font-mono text-xs break-all">{live.reference}</dd>
                <dt class="opacity-70">Customer</dt>
                <dd class="font-mono text-xs">{live.customer_id || "none"}</dd>
                <dt class="opacity-70">Created</dt>
                <dd class="text-xs">{time(live.created_at)}</dd>
              </dl>
            </.async_result>
          </div>
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <form phx-submit="refund" class="rounded-box bg-base-100 p-4 space-y-2">
            <h3 class="font-medium">
              Refund <span class="badge badge-ghost badge-sm">:refund action</span>
            </h3>
            <input type="hidden" name="payment" value={@selected.payment.id} />
            <div class="flex flex-wrap gap-2">
              <input
                name="amount"
                type="number"
                step="0.01"
                min="0.01"
                placeholder="amount, empty = all"
                class="input input-sm w-44"
              />
              <select name="reason" class="select select-sm w-48">
                <option value="">No reason</option>
                <option value="requested_by_customer">Requested by customer</option>
                <option value="duplicate">Duplicate</option>
                <option value="fraudulent">Fraudulent</option>
              </select>
              <button class="btn btn-sm btn-warning" phx-disable-with="Refunding...">Refund</button>
            </div>
            <div :if={@selected.refund} class="text-sm">
              <span class="opacity-70">Last refund:</span>
              <code>{@selected.refund.id}</code>
              · {Money.to_string!(@selected.refund.amount)} · {@selected.refund.status}
            </div>
          </form>

          <div class="rounded-box bg-base-100 p-4">
            <h3 class="font-medium mb-2">Webhook events about it</h3>
            <p :if={@selected.events == []} class="text-sm opacity-70">
              None yet. They come with <code>stripe listen</code>.
            </p>
            <ul class="text-sm space-y-1">
              <li :for={event <- @selected.events} class="flex gap-2">
                <code>{event.type}</code> <span class="badge badge-sm">{event.status}</span>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :checkout, :map, required: true

  def checkout_card(assigns) do
    ~H"""
    <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm mt-3 rounded-box bg-base-200 p-4">
      <dt class="opacity-70">Checkout</dt>
      <dd class="font-mono text-xs break-all">{@checkout.id}</dd>
      <dt class="opacity-70">Status</dt>
      <dd><span class="badge badge-sm">{@checkout.status}</span></dd>
      <dt class="opacity-70">Payment</dt>
      <dd class="font-mono text-xs">{@checkout.payment_id || "none yet"}</dd>
      <dt class="opacity-70">Reference</dt>
      <dd class="font-mono text-xs break-all">{@checkout.reference}</dd>
    </dl>
    """
  end

  attr :events, :any, required: true
  attr :tenant, :string, required: true

  def inbox_table(assigns) do
    ~H"""
    <p class="text-sm opacity-70 mb-2">
      Filled by Stripe's webhooks. Run
      <code class="break-all">stripe listen --forward-to localhost:4041/pay/webhooks/stripe/{@tenant}</code>
      and put its <code>whsec_...</code>
      in <code>.env</code>.
    </p>
    <div class="overflow-x-auto rounded-box border border-base-300 max-h-80">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>Type</th>
            <th>Payment</th>
            <th>Status</th>
            <th>Error</th>
          </tr>
        </thead>
        <tbody id="inbox" phx-update="stream">
          <tr id="inbox-empty" class="only:table-row hidden">
            <td colspan="4" class="text-center opacity-70">No webhook events yet.</td>
          </tr>
          <tr :for={{dom_id, event} <- @events} id={dom_id}>
            <td><code class="text-xs">{event.type}</code></td>
            <td class="font-mono text-xs">{event.payment_id}</td>
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
            <th>Event</th>
            <th>What</th>
            <th>Outcome</th>
            <th>ms</th>
          </tr>
        </thead>
        <tbody id="telemetry" phx-update="stream">
          <tr id="telemetry-empty" class="only:table-row hidden">
            <td colspan="4" class="text-center opacity-70">Nothing yet. Buy, sync or refund.</td>
          </tr>
          <tr :for={{dom_id, entry} <- @entries} id={dom_id}>
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
    <section class="card bg-base-200">
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
              /> Once per payment
            </label>
            <label class="label">
              <input
                type="radio"
                name="refunds"
                value="many"
                class="radio radio-sm"
                checked={@setting.refunds == :many}
              /> Many part refunds
            </label>
          </fieldset>

          <fieldset class="fieldset">
            <legend class="fieldset-legend">Merchant of record</legend>
            <select name="merchant_of_record" class="select select-sm">
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
              /> Shop open
            </label>
            <label class="label">
              <input
                type="radio"
                name="open"
                value="false"
                class="radio radio-sm"
                checked={!@setting.open}
              /> Closed: every checkout is refused
            </label>
          </fieldset>
        </div>

        <div><button class="btn btn-sm">Save settings</button></div>
      </form>
    </section>
    """
  end

  attr :status, :atom, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", status_class(@status)]}>{@status}</span>
    """
  end

  @products %{
    "ebook" => "Elixir ebook",
    "course" => "LiveView course",
    "stickers" => "Sticker pack"
  }

  defp product_name(reference) when is_binary(reference) do
    [id | _] = String.split(reference, "-", parts: 2)
    Map.get(@products, id, "Sandbox payment")
  end

  defp product_name(_reference), do: "Sandbox payment"

  defp money(amount, currency), do: currency |> Money.new(amount) |> Money.to_string!()

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

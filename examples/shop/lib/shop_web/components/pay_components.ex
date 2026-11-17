defmodule ShopWeb.PayComponents do
  @moduledoc """
  The demo shop's pieces of page, each showing one part of Mishka Pay. Every part a test reads or
  presses carries a `data-testid`, so a browser test finds it without leaning on text or layout.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

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
    <p class="text-xs opacity-60 mb-2 grow-0" data-testid="code-hint">
      <code>{render_slot(@inner_block)}</code>
    </p>
    """
  end

  @doc """
  Stripe's own form inside the page, mounted by Stripe.js with a client secret and the site's
  publishable key: an embedded Checkout (`mode="embedded_checkout"`), or the Payment Element of a
  payment intent (`"payment"`) or a setup intent (`"setup"`). The form is an iframe only Stripe.js
  can mount, hence the one hook. A Payment Element is confirmed by a `stripe:confirm` event on
  its element (`JS.dispatch("stripe:confirm", to: "#" <> id)`), and then tells the part that
  shows it with a `stripe_confirmed` event (`%{"mode" => mode, "error" => message | nil}`).
  """
  attr :id, :string, required: true
  attr :mode, :string, values: ~w(embedded_checkout payment setup), required: true
  attr :client_secret, :string, required: true
  attr :publishable_key, :string, required: true
  attr :rest, :global

  def stripe_form(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".StripeForm"
      phx-update="ignore"
      data-mode={@mode}
      data-client-secret={@client_secret}
      data-publishable-key={@publishable_key}
      {@rest}
    >
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".StripeForm">
      // A hook, not LiveView.JS: Stripe's forms are iframes that only Stripe.js can mount and
      // confirm, with the client secret. The script loads once per page.
      let stripeJs
      const loadStripe = () => stripeJs ||= new Promise((resolve, reject) => {
        if (window.Stripe) return resolve(window.Stripe)
        const script = document.createElement("script")
        script.src = "https://js.stripe.com/endive/stripe.js"
        script.onload = () => resolve(window.Stripe)
        script.onerror = () => { stripeJs = null; reject(new Error("Stripe.js did not load")) }
        document.head.appendChild(script)
      })

      export default {
        async mounted() {
          const {mode, clientSecret, publishableKey} = this.el.dataset
          try {
            const stripe = (await loadStripe())(publishableKey)
            if (mode === "embedded_checkout") {
              const create = stripe.createEmbeddedCheckoutPage || stripe.initEmbeddedCheckout
              this.form = await create.call(stripe, {fetchClientSecret: async () => clientSecret})
            } else {
              const elements = stripe.elements({clientSecret})
              this.form = elements.create("payment")
              this.el.addEventListener("stripe:confirm", () => this.confirm(stripe, elements, mode))
            }
            if (this.el.isConnected) this.form.mount(this.el)
          } catch (error) {
            this.el.textContent = "Stripe's form could not load: " + error.message
          }
        },
        async confirm(stripe, elements, mode) {
          const confirm = mode === "setup" ? stripe.confirmSetup : stripe.confirmPayment
          const {error} = await confirm.call(stripe, {
            elements,
            redirect: "if_required",
            confirmParams: {return_url: window.location.href}
          })
          this.pushEventTo(this.el, "stripe_confirmed", {mode, error: error ? error.message : null})
        },
        destroyed() {
          if (this.form && this.form.destroy) this.form.destroy()
        }
      }
    </script>
    """
  end

  @doc """
  The site's publishable key that Stripe.js needs for `what` (`"An embedded checkout"`), or a
  sentence that says how to add one.
  """
  def publishable_key(tenant, what) do
    case MishkaPay.Credentials.fetch("stripe", tenant) do
      {:ok, %{publishable_key: key}} when is_binary(key) ->
        {:ok, key}

      _no_key ->
        {:error,
         "#{what} needs the site's publishable key: put STRIPE_PUBLISHABLE_KEY=pk_test_... in examples/shop/.env."}
    end
  end

  @doc """
  For the site's staff, beside an error's plain words: the provider's id of the request that
  failed (`:request_id` of `MishkaPay.Errors.Rejected` or `Declined`, found with
  `MishkaPay.Ash.provider_error/1`) and its page about the error. A buyer never sees it.
  """
  attr :error, :map, required: true

  def request_id(assigns) do
    ~H"""
    <p
      :if={@error.request_id}
      class="text-xs opacity-70 mb-3 flex flex-wrap items-center gap-2"
      data-testid="request-id"
    >
      <span>
        {MishkaPay.Provider.label_of(@error.provider)}'s request id, for its support:
      </span>
      <code class="break-all" data-testid="request-id-value">{@error.request_id}</code>
      <a
        :if={@error.doc_url}
        href={@error.doc_url}
        target="_blank"
        rel="noopener noreferrer"
        class="link"
        data-testid="request-id-doc"
      >
        about this error
      </a>
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
              <span class="block text-xs opacity-70" data-testid="site-webhook-old-secrets">
                + {length(@keys.webhook_secrets)} from before a roll, still accepted<span :if={
                  @keys.webhook_secrets == []
                }> (set <code>STRIPE_WEBHOOK_SECRET_OLD</code> to keep one)</span>
              </span>
            </dd>
            <dt class="opacity-70">Refunds</dt>
            <dd data-testid="site-refunds">{@keys.refunds}</dd>
            <dt class="opacity-70">Merchant of record</dt>
            <dd data-testid="site-merchant">{on_off(@keys.merchant_of_record)}</dd>
            <dt class="opacity-70">Stripe Tax</dt>
            <dd data-testid="site-automatic-tax">{on_off(@keys.automatic_tax)}</dd>
            <dt class="opacity-70">Shop</dt>
            <dd data-testid="site-open">
              <span class={["badge badge-sm", (@setting.open && "badge-success") || "badge-error"]}>
                {if @setting.open, do: "open", else: "closed"}
              </span>
            </dd>
            <dt class="opacity-70">PayPal</dt>
            <dd data-testid="site-paypal">{if @paypal?, do: "sandbox keys", else: "no keys"}</dd>
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
            <.plugin_row :for={plugin <- Enum.take(@plugins, 4)} plugin={plugin} />
          </ul>
          <ul
            :if={Enum.drop(@plugins, 4) != []}
            id="plugins-rest"
            class="hidden text-xs space-y-1"
            data-testid="plugins-rest"
          >
            <.plugin_row :for={plugin <- Enum.drop(@plugins, 4)} plugin={plugin} />
          </ul>
          <div :if={Enum.drop(@plugins, 4) != []}>
            <button
              id="plugins-more"
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click={
                JS.show(to: "#plugins-rest")
                |> JS.hide(to: "#plugins-more")
                |> JS.show(to: "#plugins-less")
              }
              data-testid="plugins-more"
            >
              Read more
            </button>
            <button
              id="plugins-less"
              type="button"
              class="btn btn-ghost btn-xs hidden"
              phx-click={
                JS.hide(to: "#plugins-rest")
                |> JS.hide(to: "#plugins-less")
                |> JS.show(to: "#plugins-more")
              }
              data-testid="plugins-less"
            >
              Show less
            </button>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :plugin, :map, required: true

  defp plugin_row(assigns) do
    ~H"""
    <li class="flex flex-wrap gap-1" data-testid="plugin">
      <code class="opacity-70">{@plugin.event}</code>
      <span class="font-medium">{inspect(@plugin.name)}</span>
      <span class="badge badge-ghost badge-xs">{@plugin.status}</span>
    </li>
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
        <span
          :if={@product.stripe_price_id}
          class={["badge badge-ghost badge-sm", stripe_only()]}
          title={@product.stripe_price_id}
          data-testid="product-catalog-price"
        >
          sold by Stripe price
        </span>
        <button
          name="product"
          value={@product.slug}
          class="btn btn-primary"
          phx-disable-with="Opening the payment page..."
          data-testid={"buy-#{@product.slug}"}
        >
          {if @product.interval, do: "Subscribe", else: "Buy"}
        </button>
        <p :if={!@open?} class="text-xs text-error">The shop is closed: the gate will refuse.</p>
      </div>
    </div>
    """
  end

  @doc "The optional parts of a checkout, sent with whichever product is bought."
  attr :max_quantity, :integer, required: true
  attr :paypal?, :boolean, default: false
  attr :buyer?, :boolean, default: false
  attr :typed, :map, default: %{}, doc: "what the buyer typed, kept so a reconnect gives it back"

  def checkout_options(assigns) do
    ~H"""
    <details
      class="collapse collapse-arrow bg-base-200"
      open={@typed != %{}}
      data-testid="checkout-options"
    >
      <summary class="collapse-title font-medium">
        Checkout options
        <span class="text-sm opacity-60">
          (provider, quantity, buyer, discounts, tax, language, expiry, merchant of record, metadata)
        </span>
      </summary>
      <div class="collapse-content grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <label class="fieldset">
          <span class="fieldset-legend">Pay with</span>
          <select name="provider" class="select select-sm" data-testid="option-provider">
            <option value="stripe" selected={@typed["provider"] == "stripe"}>Stripe</option>
            <option value="paypal" selected={@typed["provider"] == "paypal"} disabled={!@paypal?}>
              {if @paypal?, do: "PayPal", else: "PayPal (no keys)"}
            </option>
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
            value={@typed["quantity"] || "1"}
            class="input input-sm"
            data-testid="option-quantity"
          />
        </label>
        <label :if={!@buyer?} class="fieldset">
          <span class="fieldset-legend">Buyer email</span>
          <input
            name="email"
            value={@typed["email"]}
            type="email"
            placeholder="filled on the payment page"
            class="input input-sm"
            data-testid="option-email"
          />
        </label>
        <p
          class={["hidden text-sm opacity-70 sm:col-span-2", paypal_only()]}
          data-testid="option-paypal-note"
        >
          PayPal takes no discounts, tax, page language, expiry, billing address, customer or
          invoice options here: Mishka Pay refuses them instead of leaving them out.
        </p>
        <label class={["fieldset", stripe_only()]}>
          <span class="fieldset-legend">Merchant of record, this checkout</span>
          <select name="merchant_of_record" class="select select-sm" data-testid="option-merchant">
            <option value="" selected={@typed["merchant_of_record"] == ""}>The site's setting</option>
            <option value="on" selected={@typed["merchant_of_record"] == "on"}>On</option>
            <option value="off" selected={@typed["merchant_of_record"] == "off"}>Off</option>
          </select>
        </label>
        <div class="fieldset">
          <span class="fieldset-legend">Metadata</span>
          <div class="join">
            <input
              name="meta_key"
              value={@typed["meta_key"]}
              placeholder="key"
              class="input input-sm join-item w-24"
              data-testid="option-meta-key"
            />
            <input
              name="meta_value"
              value={@typed["meta_value"]}
              placeholder="value"
              class="input input-sm join-item w-28"
              data-testid="option-meta-value"
            />
          </div>
        </div>
        <label class={["fieldset", stripe_only()]}>
          <span class="fieldset-legend">Discount</span>
          <select name="discount_mode" class="select select-sm" data-testid="option-discount-mode">
            <option value="" selected={@typed["discount_mode"] == ""}>None</option>
            <option value="typed" selected={@typed["discount_mode"] == "typed"}>
              Buyer types a promotion code
            </option>
            <option value="code" selected={@typed["discount_mode"] == "code"}>
              Apply a promotion code (promo_...)
            </option>
            <option value="coupon" selected={@typed["discount_mode"] == "coupon"}>
              Apply a coupon (its id)
            </option>
          </select>
        </label>
        <label class={["fieldset", stripe_only()]}>
          <span class="fieldset-legend">Code or coupon id to apply</span>
          <input
            name="discount_id"
            value={@typed["discount_id"]}
            placeholder="promo_... or SPRING"
            class="input input-sm"
            data-testid="option-discount-id"
          />
        </label>
        <label class={["fieldset", stripe_only()]}>
          <span class="fieldset-legend">Page language</span>
          <select name="locale" class="select select-sm" data-testid="option-locale">
            <option value="" selected={@typed["locale"] == ""}>Stripe's choice</option>
            <option value="auto" selected={@typed["locale"] == "auto"}>The buyer's browser</option>
            <option value="en" selected={@typed["locale"] == "en"}>English</option>
            <option value="de" selected={@typed["locale"] == "de"}>German</option>
            <option value="fr" selected={@typed["locale"] == "fr"}>French</option>
            <option value="es" selected={@typed["locale"] == "es"}>Spanish</option>
            <option value="ja" selected={@typed["locale"] == "ja"}>Japanese</option>
          </select>
        </label>
        <label class={["fieldset", stripe_only()]}>
          <span class="fieldset-legend">Expires in minutes, 30 to 1440</span>
          <input
            name="expires_in"
            value={@typed["expires_in"]}
            type="number"
            min="30"
            max="1440"
            placeholder="1440 (Stripe's default)"
            class="input input-sm"
            data-testid="option-expires-in"
          />
        </label>
        <label class={["fieldset", stripe_only()]}>
          <span class="fieldset-legend">Billing address</span>
          <select name="billing_address" class="select select-sm" data-testid="option-billing-address">
            <option value="" selected={@typed["billing_address"] == ""}>Only when needed</option>
            <option value="required" selected={@typed["billing_address"] == "required"}>
              Always ask
            </option>
          </select>
        </label>
        <label class={["fieldset", stripe_only()]}>
          <span class="fieldset-legend">Make a Stripe customer, one-time only</span>
          <select
            name="customer_creation"
            class="select select-sm"
            data-testid="option-customer-creation"
          >
            <option value="" selected={@typed["customer_creation"] == ""}>Stripe's choice</option>
            <option value="always" selected={@typed["customer_creation"] == "always"}>Always</option>
            <option value="if_required" selected={@typed["customer_creation"] == "if_required"}>
              Only if needed
            </option>
          </select>
        </label>
        <div class={["fieldset gap-1", stripe_only()]}>
          <label class="fieldset">
            <span class="fieldset-legend">Stripe Tax, this checkout</span>
            <select name="automatic_tax" class="select select-sm" data-testid="option-automatic-tax">
              <option value="" selected={@typed["automatic_tax"] == ""}>The site's setting</option>
              <option value="on" selected={@typed["automatic_tax"] == "on"}>On</option>
              <option value="off" selected={@typed["automatic_tax"] == "off"}>Off</option>
            </select>
          </label>
          <label class="label gap-2 text-sm">
            <input
              type="checkbox"
              name="invoice"
              value="true"
              checked={@typed["invoice"] == "true"}
              class="checkbox checkbox-sm"
              data-testid="option-invoice"
            /> Make an invoice (one-time only)
          </label>
          <label class="label gap-2 text-sm">
            <input
              type="checkbox"
              name="tax_id_collection"
              value="true"
              checked={@typed["tax_id_collection"] == "true"}
              class="checkbox checkbox-sm"
              data-testid="option-tax-id"
            /> Business buyers give their tax id
          </label>
          <label class="label gap-2 text-sm">
            <input
              type="checkbox"
              name="hold"
              value="true"
              checked={@typed["hold"] == "true"}
              class="checkbox checkbox-sm"
              data-testid="option-hold"
            /> Open it here, go to Stripe later
          </label>
        </div>
      </div>
    </details>
    """
  end

  # The buy form (`group/buy`) shows what fits the provider picked under "Pay with" in the browser,
  # with no round trip: a redraw from the server would drop what the buyer already typed.
  defp stripe_only, do: "group-has-[option[value=paypal]:checked]/buy:hidden"
  defp paypal_only, do: "group-has-[option[value=paypal]:checked]/buy:block"

  @doc "The Stripe customer the next checkout pays as, picked in the customers part."
  attr :buyer, :map, required: true

  def buyer_bar(assigns) do
    ~H"""
    <div class="alert alert-info py-2" data-testid="buyer-bar" data-customer-id={@buyer.provider_id}>
      <.icon name="hero-user" class="size-5" />
      <span>
        Buying as <strong>{@buyer.name || @buyer.email}</strong>
        <code class="text-xs opacity-70">{@buyer.provider_id}</code>: Stripe fills their details
        and keeps the payment on their record.
      </span>
      <input type="hidden" name="customer_id" value={@buyer.provider_id} />
      <input type="hidden" name="buyer" value={@buyer.id} />
      <button
        type="button"
        class="btn btn-ghost btn-xs"
        phx-click="clear_buyer"
        data-testid="buyer-clear"
      >
        Buy as a guest
      </button>
    </div>
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
      {"4000 0000 0000 0127", "declined, wrong CVC"},
      {"4000 0000 0000 0259", "pays, then the bank disputes it (see Disputes)"}
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
      <form
        id="status-filter"
        phx-change="filter"
        class="flex flex-wrap gap-1"
        data-testid="status-filter"
      >
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
              <span
                :if={payment.disputed}
                class="badge badge-sm badge-error ml-1"
                data-testid="payment-disputed"
              >
                disputed
              </span>
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

  @doc """
  One payment: the row the shop keeps, the payment as its provider has it, its events and actions.
  A Stripe payment not paid yet has "Cancel" (`cancel_payment`), so one left waiting can be ended.
  """
  attr :selected, :map, required: true
  attr :live, :any, required: true
  attr :names, :map, required: true
  attr :refund_form, :map, default: %{"amount" => "", "reason" => ""}

  def payment_details(assigns) do
    assigns = assign(assigns, :at, MishkaPay.Provider.label_of(assigns.selected.payment.provider))

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
              <dt class="opacity-70">Made at {@at}</dt>
              <dd class="text-xs">{time(@selected.payment.provider_created_at)}</dd>
              <dt class="opacity-70">Last synced</dt>
              <dd class="text-xs" data-testid="stored-synced">{time(@selected.payment.synced_at)}</dd>
            </dl>
            <div class="flex flex-wrap gap-2 mt-3">
              <button
                class="btn btn-sm"
                phx-click="sync"
                phx-value-payment_id={@selected.payment.provider_id}
                data-testid="details-sync"
              >
                <.icon name="hero-arrow-path" class="size-4" /> Sync from {@at}
              </button>
              <button
                :if={cancelable?(@selected.payment)}
                class="btn btn-sm btn-error btn-outline"
                phx-click="cancel_payment"
                phx-value-payment={@selected.payment.id}
                phx-disable-with="Asking Stripe..."
                data-confirm="Cancel this payment on Stripe? It can no longer be paid."
                data-testid="payment-cancel"
              >
                <.icon name="hero-no-symbol" class="size-4" /> Cancel
              </button>
            </div>
            <.hint :if={cancelable?(@selected.payment)}>MishkaPay.cancel_payment_intent/3</.hint>
          </div>

          <div class="rounded-box bg-base-100 p-4" data-testid="details-live">
            <h3 class="font-medium">Live from {@at}</h3>
            <.hint>MishkaPay.fetch_payment/3</.hint>
            <.async_result :let={live} assign={@live}>
              <:loading>
                <span class="loading loading-dots loading-sm"></span> Asking {@at}...
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
            id="refund-form"
            phx-change="draft_refund"
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
                value={@refund_form["amount"]}
                placeholder="amount, empty = all"
                class="input input-sm w-44"
                data-testid="refund-amount"
              />
              <select name="reason" class="select select-sm w-60" data-testid="refund-reason">
                <option
                  :for={
                    {value, label} <- [
                      {"", "No reason"},
                      {"requested_by_customer", "Requested by customer"},
                      {"duplicate", "Duplicate"},
                      {"fraudulent", "Fraudulent (Stripe then blocks this card)"}
                    ]
                  }
                  value={value}
                  selected={@refund_form["reason"] == value}
                >
                  {label}
                </option>
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
              {if @selected.payment.provider == "stripe",
                do: "None yet. Send one with the webhook simulator below.",
                else: "None yet. #{@at} sends them to the site's webhook address as they happen."}
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

  # A Stripe payment intent no one has paid yet (waiting for a card, for the buyer, or after a
  # declined card) can still be canceled; a held one is let go under "Refunds and held payments".
  defp cancelable?(%{provider: "stripe", status: status}),
    do: status in [:pending, :requires_action, :failed]

  defp cancelable?(_payment), do: false

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
      <dt class="opacity-70">Discount</dt>
      <dd data-testid="checkout-discount">
        {(@checkout.amount_discount && Money.to_string!(@checkout.amount_discount)) || "–"}
      </dd>
      <dt :if={@checkout.invoice_id} class="opacity-70">Invoice</dt>
      <dd :if={@checkout.invoice_id} class="font-mono text-xs" data-testid="checkout-invoice">
        {@checkout.invoice_id}
      </dd>
      <dt :if={@checkout.payment_link_id} class="opacity-70">From payment link</dt>
      <dd :if={@checkout.payment_link_id} class="font-mono text-xs" data-testid="checkout-link">
        {@checkout.payment_link_id}
      </dd>
      <dt :if={@checkout.expires_at} class="opacity-70">Expires</dt>
      <dd :if={@checkout.expires_at} class="text-xs" data-testid="checkout-expires">
        {Calendar.strftime(@checkout.expires_at, "%Y-%m-%d %H:%M")} UTC
      </dd>
      <dt class="opacity-70">Buyer email</dt>
      <dd data-testid="checkout-email">{(@checkout.customer && @checkout.customer.email) || "–"}</dd>
      <dt class="opacity-70">Payment</dt>
      <dd class="font-mono text-xs" data-testid="checkout-payment">
        {@checkout.payment_id || "none yet"}
      </dd>
      <dt class="opacity-70">Reference</dt>
      <dd class="font-mono text-xs break-all">{@checkout.reference}</dd>
      <dd :if={@checkout.status == :open} class="col-span-2 flex flex-wrap gap-2 mt-2">
        <a
          :if={@checkout.url}
          href={@checkout.url}
          class="btn btn-sm btn-primary"
          data-testid="checkout-go"
        >
          Go to Stripe's page
        </a>
        <button
          class="btn btn-sm btn-warning"
          phx-click="expire_checkout"
          phx-value-id={@checkout.id}
          phx-disable-with="Asking Stripe..."
          data-testid="checkout-expire"
        >
          End this checkout
        </button>
        <span class="text-xs opacity-70 self-center">
          Ending it frees what it held: Stripe's page then refuses to take payment. Tax is counted
          once the buyer gives an address there: read the checkout back for the final total.
        </span>
      </dd>
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

  defp simulated_meaning(:rolled_secret),
    do:
      "Taken: after a roll Stripe signs with the old secret for a while, and the site still lists it (webhook_secrets)."

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
      "A listener could not take it: 500, so Stripe sends it again later. The inbox already kept the event, so when Stripe sends it again it is stored once (the row can be processed while the answer was 500)."

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
            <legend class="fieldset-legend">Stripe Tax for every checkout</legend>
            <label class="label">
              <input
                type="checkbox"
                name="automatic_tax"
                value="true"
                class="checkbox checkbox-sm"
                checked={@setting.automatic_tax}
                data-testid="setting-automatic-tax"
              /> Count the tax from the buyer's address
            </label>
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

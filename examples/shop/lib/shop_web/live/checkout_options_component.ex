defmodule ShopWeb.CheckoutOptionsComponent do
  @moduledoc """
  More checkout options of the demo shop, each one a field of `MishkaPay.Checkout` sent through
  `Shop.Pay.Payment`'s `:start_checkout`: the buyer's phone, the site's terms, up to three
  questions (text, numeric or dropdown), a description, a card statement suffix, the pay
  button's word, a plan's trial without a card, a plan's billing mode and proration discounts
  (`:billing_mode`, `:proration_discounts`), shipping countries with an inline shipping rate,
  and pay later (`capture: :manual`, then Capture or Cancel under "Refunds and held payments").

  The checkout opens on Stripe's page, or embedded in this page (`ui_mode: :embedded`): Stripe.js
  mounts it with the checkout's client secret and the site's publishable key. "Read it back"
  (`MishkaPay.fetch_checkout/3`) shows what the buyer gave: phone, answers, terms, shipping
  address, and the items sold.
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents,
    only: [section_title: 1, hint: 1, stripe_form: 1, publishable_key: 2]

  @form %{
    "product" => nil,
    "ui_mode" => "hosted",
    "merchant_of_record" => "",
    "submit_type" => "",
    "billing_mode" => "",
    "proration_discounts" => "",
    "q1_type" => "text",
    "q2_type" => "text",
    "q3_type" => "text"
  }

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, embedded: nil, read: nil, form: @form, readback_id: "")}

  @impl true
  def update(assigns, socket) do
    products = Shop.Catalog.all()
    first = Enum.at(products, 0, %{slug: nil}).slug

    {:ok,
     socket
     |> assign(tenant: assigns.tenant, products: products)
     |> update(:form, &Map.update!(&1, "product", fn slug -> slug || first end))}
  end

  # Everything typed or picked is kept, so a re-render (the checkout opening, a read back)
  # shows the same choices and a second checkout sends them again.
  @impl true
  def handle_event("draft", params, socket), do: {:noreply, keep(socket, params)}

  def handle_event("start", %{"product" => slug} = params, socket) do
    socket = keep(socket, params)

    with %{} = product <- Shop.Catalog.fetch(slug),
         {:ok, keys} <- keys(params["ui_mode"], socket.assigns.tenant),
         {:ok, checkout} <- start_checkout(product, params, socket.assigns.tenant) do
      {:noreply, open(socket, checkout, keys)}
    else
      nil -> {:noreply, say(socket, :error, "That product is not on sale.")}
      {:error, error} -> {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("close_embedded", _params, socket),
    do: {:noreply, assign(socket, embedded: nil)}

  def handle_event("type_read", %{"checkout_id" => value}, socket),
    do: {:noreply, assign(socket, readback_id: value)}

  def handle_event("read", %{"checkout_id" => value}, socket) do
    socket = assign(socket, readback_id: value)

    with {:ok, id} <- checkout_id(value),
         {:ok, checkout} <- MishkaPay.fetch_checkout("stripe", id, socket.assigns.tenant) do
      {:noreply, assign(socket, read: checkout)}
    else
      {:error, error} ->
        {:noreply, socket |> assign(read: nil) |> say(:error, MishkaPay.Ash.message(error))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="checkout-more" class="space-y-4">
      <.section_title icon="hero-adjustments-horizontal" title="Checkout options" />
      <p class="text-sm opacity-70">
        Questions for the buyer, terms, shipping, a trial without a card, pay later, and Stripe's form
        inside this page. Pick a product, set what you want, open the checkout.
      </p>

      <form
        id="checkout-more-form"
        phx-change="draft"
        phx-submit="start"
        phx-target={@myself}
        class="rounded-box bg-base-200 p-4 space-y-4"
        data-testid="checkout-more-form"
      >
        <.hint>Shop.Pay.Payment :start_checkout with MishkaPay.Checkout's options</.hint>
        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <label class="fieldset">
            <span class="fieldset-legend">Product</span>
            <select name="product" class="select select-sm" data-testid="more-product">
              <option
                :for={product <- @products}
                value={product.slug}
                selected={@form["product"] == product.slug}
              >
                {product.name} (${product.price}{if Shop.Catalog.plan?(product),
                  do: " / #{product.interval}"})
              </option>
            </select>
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Where the buyer pays</span>
            <select name="ui_mode" class="select select-sm" data-testid="more-ui-mode">
              <option value="hosted" selected={@form["ui_mode"] == "hosted"}>On Stripe's page</option>
              <option value="embedded" selected={@form["ui_mode"] == "embedded"}>
                Embedded in this page
              </option>
            </select>
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Merchant of record, this checkout</span>
            <select name="merchant_of_record" class="select select-sm" data-testid="more-merchant">
              <option
                :for={{value, label} <- [{"", "The site's setting"}, {"on", "On"}, {"off", "Off"}]}
                value={value}
                selected={@form["merchant_of_record"] == value}
              >
                {label}
              </option>
            </select>
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Pay button says (one-time only)</span>
            <select name="submit_type" class="select select-sm" data-testid="more-submit-type">
              <option
                :for={
                  {value, label} <- [
                    {"", "Stripe's choice"},
                    {"pay", "Pay"},
                    {"book", "Book"},
                    {"donate", "Donate"},
                    {"auto", "Auto"}
                  ]
                }
                value={value}
                selected={@form["submit_type"] == value}
              >
                {label}
              </option>
            </select>
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Billing mode (plans only)</span>
            <select name="billing_mode" class="select select-sm" data-testid="more-billing-mode">
              <option
                :for={
                  {value, label} <- [
                    {"", "The site's setting (flexible)"},
                    {"flexible", "Flexible"},
                    {"classic", "Classic"}
                  ]
                }
                value={value}
                selected={@form["billing_mode"] == value}
              >
                {label}
              </option>
            </select>
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Proration discounts (flexible only)</span>
            <select
              name="proration_discounts"
              class="select select-sm"
              data-testid="more-proration-discounts"
            >
              <option
                :for={
                  {value, label} <- [
                    {"", "The site's setting (itemized)"},
                    {"itemized", "Itemized"},
                    {"included", "Included"}
                  ]
                }
                value={value}
                selected={@form["proration_discounts"] == value}
              >
                {label}
              </option>
            </select>
          </label>
          <label class="fieldset sm:col-span-2">
            <span class="fieldset-legend">Description</span>
            <input
              name="description"
              value={@form["description"]}
              placeholder="shown at Stripe on the payment"
              class="input input-sm"
              data-testid="more-description"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Card statement suffix</span>
            <input
              name="statement_suffix"
              value={@form["statement_suffix"]}
              maxlength="22"
              placeholder="ORDER 42"
              class="input input-sm"
              data-testid="more-statement-suffix"
            />
            <span class="text-xs opacity-60">
              Stripe refuses it while merchant of record is on.
            </span>
          </label>
          <div class="fieldset gap-1">
            <label class="label gap-2 text-sm">
              <input
                type="checkbox"
                name="phone"
                value="true"
                checked={@form["phone"] == "true"}
                class="checkbox checkbox-sm"
                data-testid="more-phone"
              /> Ask for a phone number
            </label>
            <label class="label gap-2 text-sm">
              <input
                type="checkbox"
                name="terms"
                value="true"
                checked={@form["terms"] == "true"}
                class="checkbox checkbox-sm"
                data-testid="more-terms"
              /> Buyer accepts the terms
            </label>
            <label class="label gap-2 text-sm">
              <input
                type="checkbox"
                name="pay_later"
                value="true"
                checked={@form["pay_later"] == "true"}
                class="checkbox checkbox-sm"
                data-testid="more-pay-later"
              /> Pay later: only hold the money (one-time only)
            </label>
          </div>
        </div>

        <div class="space-y-2" data-testid="more-questions">
          <h4 class="text-sm font-medium">Questions on the page, up to 3</h4>
          <div :for={n <- 1..3} class="grid gap-2 sm:grid-cols-4 items-end">
            <input
              name={"q#{n}_label"}
              value={@form["q#{n}_label"]}
              placeholder={"Question #{n}, such as Name on the certificate"}
              class="input input-sm sm:col-span-2"
              data-testid={"more-q#{n}-label"}
            />
            <select name={"q#{n}_type"} class="select select-sm" data-testid={"more-q#{n}-type"}>
              <option
                :for={
                  {value, label} <- [
                    {"text", "Text"},
                    {"numeric", "Numbers"},
                    {"dropdown", "Dropdown"}
                  ]
                }
                value={value}
                selected={@form["q#{n}_type"] == value}
              >
                {label}
              </option>
            </select>
            <div class="flex items-center gap-2">
              <input
                name={"q#{n}_options"}
                value={@form["q#{n}_options"]}
                placeholder="Dropdown: Pro, Team"
                class="input input-sm min-w-0 flex-1"
                data-testid={"more-q#{n}-options"}
              />
              <label class="label gap-1 text-xs">
                <input
                  type="checkbox"
                  name={"q#{n}_optional"}
                  value="true"
                  checked={@form["q#{n}_optional"] == "true"}
                  class="checkbox checkbox-xs"
                  data-testid={"more-q#{n}-optional"}
                /> optional
              </label>
            </div>
          </div>
        </div>

        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <label class="fieldset">
            <span class="fieldset-legend">Plan trial, days</span>
            <input
              name="trial_days"
              value={@form["trial_days"]}
              type="number"
              min="1"
              placeholder="the plan's own"
              class="input input-sm"
              data-testid="more-trial-days"
            />
          </label>
          <label class="label gap-2 text-sm self-end pb-2">
            <input
              type="checkbox"
              name="no_card"
              value="true"
              checked={@form["no_card"] == "true"}
              class="checkbox checkbox-sm"
              data-testid="more-no-card"
            /> Trial without a card
          </label>
          <label class="fieldset sm:col-span-2">
            <span class="fieldset-legend">Ship to countries</span>
            <input
              name="shipping_countries"
              value={@form["shipping_countries"]}
              placeholder="NL, DE, US"
              class="input input-sm"
              data-testid="more-shipping-countries"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Shipping rate name (one-time only)</span>
            <input
              name="ship_name"
              value={@form["ship_name"]}
              placeholder="Standard post"
              class="input input-sm"
              data-testid="more-ship-name"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Shipping costs, USD</span>
            <input
              name="ship_amount"
              value={@form["ship_amount"]}
              placeholder="4.95, or 0 for free"
              class="input input-sm"
              data-testid="more-ship-amount"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Arrives in days, from and to</span>
            <div class="join">
              <input
                name="ship_min"
                value={@form["ship_min"]}
                type="number"
                min="1"
                placeholder="2"
                class="input input-sm join-item w-20"
                data-testid="more-ship-min"
              />
              <input
                name="ship_max"
                value={@form["ship_max"]}
                type="number"
                min="1"
                placeholder="5"
                class="input input-sm join-item w-20"
                data-testid="more-ship-max"
              />
            </div>
          </label>
        </div>

        <button
          class="btn btn-sm btn-primary"
          phx-disable-with="Asking Stripe..."
          data-testid="more-start"
        >
          Open the checkout
        </button>
      </form>

      <div
        :if={@embedded}
        class="rounded-box border border-primary/40 bg-base-100 p-4 space-y-2"
        data-testid="embedded-box"
        data-checkout-id={@embedded.id}
      >
        <div class="flex items-center gap-2">
          <h3 class="font-medium flex-1">
            Stripe's form, inside this page <code class="text-xs opacity-60">{@embedded.id}</code>
          </h3>
          <button
            class="btn btn-ghost btn-sm"
            phx-click="close_embedded"
            phx-target={@myself}
            data-testid="embedded-close"
          >
            Close
          </button>
        </div>
        <.hint>ui_mode: :embedded, Stripe.js createEmbeddedCheckoutPage</.hint>
        <.stripe_form
          id={"embedded-checkout-#{@embedded.id}"}
          mode="embedded_checkout"
          client_secret={@embedded.client_secret}
          publishable_key={@embedded.publishable_key}
          data-testid="embedded-checkout"
        />
      </div>

      <div class="space-y-3" data-testid="checkout-readback">
        <form
          id="checkout-readback-form"
          phx-change="type_read"
          phx-submit="read"
          phx-target={@myself}
          class="join w-full max-w-2xl"
          data-testid="readback-form"
        >
          <input
            name="checkout_id"
            value={@readback_id}
            placeholder="cs_test_... to read back"
            class="input input-sm join-item min-w-0 flex-1"
            data-testid="readback-input"
          />
          <button class="btn btn-sm join-item" data-testid="readback-submit">Read it back</button>
        </form>
        <.readback :if={@read} checkout={@read} />
      </div>
    </section>
    """
  end

  attr :checkout, :map, required: true

  defp readback(assigns) do
    ~H"""
    <dl
      class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm rounded-box bg-base-200 p-4"
      data-testid="readback-card"
    >
      <dt class="opacity-70">Checkout</dt>
      <dd class="font-mono text-xs break-all" data-testid="readback-id">{@checkout.id}</dd>
      <dt class="opacity-70">Status</dt>
      <dd data-testid="readback-status"><span class="badge badge-sm">{@checkout.status}</span></dd>
      <dt class="opacity-70">Phone</dt>
      <dd data-testid="readback-phone">{@checkout.phone_number || "–"}</dd>
      <dt class="opacity-70">Answers</dt>
      <dd data-testid="readback-fields">
        <span :if={(@checkout.field_values || %{}) == %{}}>–</span>
        <span
          :for={{key, value} <- @checkout.field_values || %{}}
          class="block"
          data-testid="readback-field"
          data-key={key}
        >
          {key}: {value || "–"}
        </span>
      </dd>
      <dt class="opacity-70">Terms accepted</dt>
      <dd data-testid="readback-terms">{yes_no(@checkout.terms_accepted)}</dd>
      <dt class="opacity-70">Ship to</dt>
      <dd data-testid="readback-shipping">{address(@checkout.shipping_address)}</dd>
      <dt :if={@checkout.amount_shipping} class="opacity-70">Shipping</dt>
      <dd :if={@checkout.amount_shipping} data-testid="readback-shipping-amount">
        {Money.to_string!(@checkout.amount_shipping)}
      </dd>
      <dt class="opacity-70">Total</dt>
      <dd data-testid="readback-total">
        {(@checkout.amount_total && Money.to_string!(@checkout.amount_total)) || "–"}
      </dd>
      <dt class="opacity-70">Items sold</dt>
      <dd data-testid="readback-items">
        <span :if={@checkout.items in [nil, []]}>–</span>
        <span
          :for={item <- @checkout.items || []}
          class="block"
          data-testid="readback-item"
          data-price-id={item.id}
        >
          {item.quantity} × {item.name || item.id} · {item.amount && Money.to_string!(item.amount)}
        </span>
      </dd>
      <dt class="opacity-70">Payment</dt>
      <dd class="font-mono text-xs" data-testid="readback-payment">
        {@checkout.payment_id || @checkout.subscription_id || "none yet"}
      </dd>
    </dl>
    """
  end

  defp start_checkout(product, params, tenant) do
    Shop.Pay.Payment
    |> Ash.ActionInput.for_action(:start_checkout, %{
      checkout: checkout(product, params, tenant)
    })
    |> Ash.run_action(authorize?: false)
  end

  # Only the options the form sets; the rest stays Stripe's default.
  defp checkout(product, params, tenant) do
    plan? = Shop.Catalog.plan?(product)

    %{
      provider: "stripe",
      tenant: tenant,
      mode: if(plan?, do: :subscription, else: :payment),
      items: [item(product)],
      reference: Shop.Catalog.reference(product),
      merchant_of_record: on_off(params["merchant_of_record"]),
      phone: checked(params["phone"]),
      terms: checked(params["terms"]),
      fields: fields(params),
      description: blank_nil(params["description"]),
      statement_suffix: blank_nil(params["statement_suffix"]),
      submit_type: blank_nil(params["submit_type"]),
      trial_days: if(plan?, do: integer(params["trial_days"]) || product.trial_days),
      billing_mode: if(plan?, do: blank_nil(params["billing_mode"])),
      proration_discounts: if(plan?, do: blank_nil(params["proration_discounts"])),
      card_required: if(params["no_card"] == "true", do: false),
      shipping_countries: countries(params["shipping_countries"]),
      shipping_rates: shipping_rates(params),
      capture: (params["pay_later"] == "true" && :manual) || nil
    }
    |> Map.merge(pages(params["ui_mode"]))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp pages("embedded") do
    %{ui_mode: :embedded, return_url: url(~p"/") <> "?session_id={CHECKOUT_SESSION_ID}"}
  end

  defp pages(_hosted) do
    %{
      success_url: url(~p"/") <> "?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: url(~p"/?canceled=1")
    }
  end

  defp item(%{stripe_price_id: price_id}) when is_binary(price_id),
    do: %{id: price_id, quantity: 1}

  defp item(product) do
    %{
      name: product.name,
      amount: %{amount: product.price, currency: "USD"},
      tax_code: product.tax_code,
      quantity: 1,
      interval: product.interval,
      interval_count: product.interval && product.interval_count
    }
  end

  # Each question with a label: its key is the label in letters and digits, as Stripe takes it.
  defp fields(params) do
    questions =
      for n <- 1..3,
          label = blank_nil(params["q#{n}_label"]),
          do: question(n, label, params)

    if questions == [], do: nil, else: questions
  end

  defp question(n, label, params) do
    type = params["q#{n}_type"] || "text"

    %{
      key: key(label, "question#{n}"),
      label: label,
      type: type,
      optional: params["q#{n}_optional"] == "true",
      options: options(type, params["q#{n}_options"])
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp options("dropdown", text) do
    for label <- String.split(text || "", ",", trim: true),
        label = String.trim(label),
        label != "",
        do: %{value: key(label, label), label: label}
  end

  defp options(_type, _text), do: nil

  defp key(label, fallback) do
    case label |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "") do
      "" -> fallback
      key -> String.slice(key, 0, 200)
    end
  end

  defp countries(text) do
    case for(code <- String.split(text || "", ~r/[\s,]+/, trim: true), do: code) do
      [] -> nil
      codes -> codes
    end
  end

  # An inline rate: a name and what it costs, in the items' currency.
  defp shipping_rates(params) do
    case {blank_nil(params["ship_name"]), blank_nil(params["ship_amount"])} do
      {nil, _amount} ->
        nil

      {name, amount} ->
        [
          %{
            name: name,
            amount: %{amount: amount || "0", currency: "USD"},
            min_days: integer(params["ship_min"]),
            max_days: integer(params["ship_max"])
          }
          |> Map.reject(fn {_key, value} -> is_nil(value) end)
        ]
    end
  end

  # An embedded checkout needs the site's publishable key for Stripe.js.
  defp keys("embedded", tenant), do: publishable_key(tenant, "An embedded checkout")

  defp keys(_hosted, _tenant), do: {:ok, nil}

  defp open(socket, %{ui_mode: :embedded} = checkout, publishable_key) do
    socket
    |> assign(
      embedded: %{
        id: checkout.id,
        client_secret: checkout.client_secret,
        publishable_key: publishable_key
      }
    )
    |> say(:info, "Stripe's form is below. Pay with 4242 4242 4242 4242.")
  end

  defp open(socket, %{url: url}, _key), do: redirect(socket, external: url)

  defp checkout_id(value) do
    case blank_nil(value) do
      nil -> {:error, "Type a checkout id first, it starts with cs_."}
      "pi_" <> _ -> {:error, ~s|That is a payment id (pi_). Use "Read payment" above.|}
      id -> {:ok, id}
    end
  end

  defp address(nil), do: "–"

  defp address(address) do
    [address.name, address.line1, address.line2, address.postal_code, address.city, address.state]
    |> Enum.concat([address.country])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end

  defp checked("true"), do: true
  defp checked(_off), do: nil

  defp on_off("on"), do: true
  defp on_off("off"), do: false
  defp on_off(_default), do: nil

  defp integer(value) do
    case Integer.parse(String.trim(value || "")) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
  defp yes_no(nil), do: "–"

  defp blank_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_nil(_none), do: nil

  defp keep(socket, params) do
    typed = Map.reject(params, fn {key, _value} -> String.starts_with?(key, "_") end)
    assign(socket, form: Map.merge(@form, typed))
  end

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end
end

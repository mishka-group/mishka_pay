defmodule ShopWeb.CardFormComponent do
  @moduledoc """
  A card form of the shop's own, in the demo shop: Stripe's Payment Element inside this page,
  without a checkout page. "Make payment intent" makes one on the server
  (`MishkaPay.create_payment_intent/1`) and Stripe.js mounts the form with its client secret and
  the site's publishable key (`ShopWeb.PayComponents.stripe_form/1`); "Pay" confirms it in the
  browser, and the page reads it back (`MishkaPay.fetch_payment_intent/3`). "Save a card" does
  the same with a setup intent (`MishkaPay.create_setup_intent/1`), which charges nothing.

  Each intent can also be confirmed on the server with one of Stripe's test payment methods
  (`confirm_payment_intent/4`, `confirm_setup_intent/4`), read again, or canceled
  (`cancel_payment_intent/3`, `cancel_setup_intent/3`). Nothing is asked of Stripe until a button
  is pressed.
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents,
    only: [section_title: 1, hint: 1, stripe_form: 1, publishable_key: 2]

  @payment_form %{
    "amount" => "12.00",
    "currency" => "USD",
    "capture" => "automatic",
    "customer_id" => "",
    "save" => "false"
  }

  @setup_form %{"customer_id" => "", "usage" => "off_session"}

  @test_methods [
    {"pm_card_mastercard", "Mastercard, pays"},
    {"pm_card_visa", "Visa, pays"},
    {"pm_card_threeDSecure2Required", "3D Secure, asks the buyer"},
    {"pm_card_chargeDeclined", "Declined"}
  ]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open?: false,
       publishable_key: nil,
       payment: nil,
       setup: nil,
       payment_form: @payment_form,
       setup_form: @setup_form,
       test_method: %{"payment" => "pm_card_mastercard", "setup" => "pm_card_mastercard"},
       notice: nil,
       error: nil
     )}
  end

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, tenant: assigns.tenant)}

  @impl true
  def handle_event("show", _params, socket), do: {:noreply, assign(socket, open?: true)}

  # What is typed or picked is kept, so another part re-rendering does not reset these forms.
  def handle_event("draft_payment", params, socket),
    do: {:noreply, assign(socket, payment_form: Map.take(params, Map.keys(@payment_form)))}

  def handle_event("draft_setup", params, socket),
    do: {:noreply, assign(socket, setup_form: Map.take(params, Map.keys(@setup_form)))}

  def handle_event("pick_test_method", %{"kind" => kind, "payment_method" => method}, socket),
    do: {:noreply, update(socket, :test_method, &Map.put(&1, kind, method))}

  def handle_event("create_payment", params, socket) do
    form = Map.take(params, Map.keys(@payment_form))

    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      amount: %{amount: form["amount"], currency: form["currency"]},
      capture: form["capture"],
      customer_id: blank(form["customer_id"]),
      setup_future_usage: (form["save"] == "true" && :off_session) || nil
    }

    socket = assign(socket, payment_form: form)

    with {:ok, key} <- publishable_key(socket.assigns.tenant, "A card form"),
         {:ok, intent} <- MishkaPay.create_payment_intent(attrs) do
      {:noreply,
       socket
       |> assign(payment: intent, publishable_key: key)
       |> done("Payment intent #{intent.id} made: Stripe's form is below.")}
    else
      {:error, error} -> {:noreply, failed(socket, error)}
    end
  end

  def handle_event("create_setup", params, socket) do
    form = Map.take(params, Map.keys(@setup_form))

    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      customer_id: blank(form["customer_id"]),
      usage: form["usage"]
    }

    socket = assign(socket, setup_form: form)

    with {:ok, key} <- publishable_key(socket.assigns.tenant, "A card form"),
         {:ok, intent} <- MishkaPay.create_setup_intent(attrs) do
      {:noreply,
       socket
       |> assign(setup: intent, publishable_key: key)
       |> done("Setup intent #{intent.id} made: Stripe's form is below.")}
    else
      {:error, error} -> {:noreply, failed(socket, error)}
    end
  end

  def handle_event("stripe_confirmed", %{"mode" => kind} = params, socket) do
    socket = show(socket, kind, fetch(socket, kind), "read again")

    case params["error"] do
      nil -> {:noreply, socket}
      message -> {:noreply, failed(socket, "Stripe said: " <> message)}
    end
  end

  def handle_event("read", %{"kind" => kind}, socket),
    do: {:noreply, show(socket, kind, fetch(socket, kind), "read again")}

  def handle_event("confirm_server", %{"kind" => kind, "payment_method" => method}, socket) do
    socket = update(socket, :test_method, &Map.put(&1, kind, method))
    opts = [payment_method_id: method, return_url: ShopWeb.Endpoint.url() <> "/"]
    {:noreply, show(socket, kind, confirm(socket, kind, opts), "confirmed on the server")}
  end

  def handle_event("cancel", %{"kind" => kind}, socket),
    do: {:noreply, show(socket, kind, cancel(socket, kind), "canceled")}

  defp fetch(%{assigns: %{payment: intent, tenant: tenant}}, "payment"),
    do: MishkaPay.fetch_payment_intent("stripe", intent.id, tenant)

  defp fetch(%{assigns: %{setup: intent, tenant: tenant}}, "setup"),
    do: MishkaPay.fetch_setup_intent("stripe", intent.id, tenant)

  defp confirm(%{assigns: %{payment: intent, tenant: tenant}}, "payment", opts),
    do: MishkaPay.confirm_payment_intent("stripe", intent.id, tenant, opts)

  defp confirm(%{assigns: %{setup: intent, tenant: tenant}}, "setup", opts),
    do: MishkaPay.confirm_setup_intent("stripe", intent.id, tenant, opts)

  defp cancel(%{assigns: %{payment: intent, tenant: tenant}}, "payment"),
    do: MishkaPay.cancel_payment_intent("stripe", intent.id, tenant)

  defp cancel(%{assigns: %{setup: intent, tenant: tenant}}, "setup"),
    do: MishkaPay.cancel_setup_intent("stripe", intent.id, tenant)

  defp show(socket, "payment", {:ok, intent}, what),
    do: socket |> assign(payment: intent) |> done("#{intent.id} #{what}: #{intent.status}.")

  defp show(socket, "setup", {:ok, intent}, what),
    do: socket |> assign(setup: intent) |> done("#{intent.id} #{what}: #{intent.status}.")

  defp show(socket, _kind, {:error, error}, _what), do: failed(socket, error)

  defp done(socket, notice), do: assign(socket, notice: notice, error: nil)

  defp failed(socket, message) when is_binary(message),
    do: assign(socket, error: message, notice: nil)

  defp failed(socket, error), do: failed(socket, MishkaPay.Ash.message(error))

  defp blank(nil), do: nil

  defp blank(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, test_methods: @test_methods)

    ~H"""
    <section data-testid="card-form" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <.section_title icon="hero-credit-card" title="Card form (Elements)" />
        <button
          :if={!@open?}
          class="btn btn-sm"
          phx-click="show"
          phx-target={@myself}
          data-testid="card-form-show"
        >
          Show card form
        </button>
      </div>
      <p class="text-sm opacity-70">
        Stripe's Payment Element inside this page: a payment, or a card saved for later, without a checkout page.
      </p>

      <div :if={@notice} role="status" class="alert alert-success py-2" data-testid="card-form-notice">
        {@notice}
      </div>
      <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="card-form-error">
        {@error}
      </div>

      <div :if={@open?} class="grid gap-6 lg:grid-cols-2">
        <div class="space-y-3">
          <h3 class="font-semibold">Pay</h3>
          <.hint>
            MishkaPay.create_payment_intent/1, fetch_payment_intent/3, confirm_payment_intent/4, cancel_payment_intent/3
          </.hint>
          <form
            id="card-payment-form"
            phx-change="draft_payment"
            phx-submit="create_payment"
            phx-target={@myself}
            class="flex flex-wrap items-end gap-2 rounded-box bg-base-200 p-3"
            data-testid="card-payment-form"
          >
            <label class="fieldset">
              <span class="fieldset-legend">Amount</span>
              <input
                name="amount"
                value={@payment_form["amount"]}
                inputmode="decimal"
                class="input input-sm w-24"
                data-testid="card-payment-amount"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Currency</span>
              <input
                name="currency"
                value={@payment_form["currency"]}
                maxlength="3"
                class="input input-sm w-16"
                data-testid="card-payment-currency"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Take the money</span>
              <select name="capture" class="select select-sm" data-testid="card-payment-capture">
                <option value="automatic" selected={@payment_form["capture"] == "automatic"}>
                  at once
                </option>
                <option value="manual" selected={@payment_form["capture"] == "manual"}>
                  hold it
                </option>
              </select>
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Customer</span>
              <input
                name="customer_id"
                value={@payment_form["customer_id"]}
                placeholder="cus_... (optional)"
                class="input input-sm w-36"
                data-testid="card-payment-customer"
              />
            </label>
            <label class="label text-sm">
              <input type="hidden" name="save" value="false" />
              <input
                type="checkbox"
                name="save"
                value="true"
                checked={@payment_form["save"] == "true"}
                class="checkbox checkbox-xs"
                data-testid="card-payment-save"
              /> keep the card
            </label>
            <button class="btn btn-sm btn-primary" data-testid="card-payment-create">
              Make payment intent
            </button>
          </form>

          <.intent
            :if={@payment}
            kind="payment"
            intent={@payment}
            publishable_key={@publishable_key}
            test_methods={@test_methods}
            test_method={@test_method["payment"]}
            myself={@myself}
          />
        </div>

        <div class="space-y-3">
          <h3 class="font-semibold">Save a card</h3>
          <.hint>
            MishkaPay.create_setup_intent/1, fetch_setup_intent/3, confirm_setup_intent/4, cancel_setup_intent/3
          </.hint>
          <form
            id="card-setup-form"
            phx-change="draft_setup"
            phx-submit="create_setup"
            phx-target={@myself}
            class="flex flex-wrap items-end gap-2 rounded-box bg-base-200 p-3"
            data-testid="card-setup-form"
          >
            <label class="fieldset">
              <span class="fieldset-legend">Customer</span>
              <input
                name="customer_id"
                value={@setup_form["customer_id"]}
                placeholder="cus_... keeps the card"
                class="input input-sm w-40"
                data-testid="card-setup-customer"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Charged later</span>
              <select name="usage" class="select select-sm" data-testid="card-setup-usage">
                <option value="off_session" selected={@setup_form["usage"] == "off_session"}>
                  without the buyer
                </option>
                <option value="on_session" selected={@setup_form["usage"] == "on_session"}>
                  by the buyer
                </option>
              </select>
            </label>
            <button class="btn btn-sm btn-primary" data-testid="card-setup-create">Save a card</button>
          </form>

          <.intent
            :if={@setup}
            kind="setup"
            intent={@setup}
            publishable_key={@publishable_key}
            test_methods={@test_methods}
            test_method={@test_method["setup"]}
            myself={@myself}
          />
        </div>
      </div>
    </section>
    """
  end

  attr :kind, :string, required: true
  attr :intent, :map, required: true
  attr :publishable_key, :string, required: true
  attr :test_methods, :list, required: true
  attr :test_method, :string, required: true
  attr :myself, :any, required: true

  defp intent(assigns) do
    assigns = assign(assigns, element: "card-#{assigns.kind}-element-#{assigns.intent.id}")

    ~H"""
    <div
      class="rounded-box border border-primary/40 p-3 space-y-2"
      data-testid={"card-#{@kind}-intent"}
      data-intent-id={@intent.id}
    >
      <p class="text-sm">
        <code class="text-xs">{@intent.id}</code>
        <span class="badge badge-sm" data-testid={"card-#{@kind}-status"}>{@intent.status}</span>
        <span :if={@kind == "payment"}>{Money.to_string!(@intent.amount)}</span>
        <span :if={@intent.payment_method_id} class="text-xs opacity-70">
          card <code data-testid={"card-#{@kind}-method"}>{@intent.payment_method_id}</code>
        </span>
      </p>
      <p
        :if={@intent.failure_message}
        class="text-sm text-error"
        data-testid={"card-#{@kind}-failure"}
      >
        {@intent.failure_message}
      </p>
      <div :if={
        @intent.status in [:requires_payment_method, :requires_confirmation, :requires_action]
      }>
        <.stripe_form
          id={@element}
          mode={@kind}
          client_secret={@intent.client_secret}
          publishable_key={@publishable_key}
          class="min-h-24"
          phx-target={@myself}
          data-testid={"card-#{@kind}-element"}
        />
        <button
          class="btn btn-sm btn-primary mt-2"
          phx-click={JS.dispatch("stripe:confirm", to: "#" <> @element)}
          data-testid={"card-#{@kind}-confirm"}
        >
          {if @kind == "payment", do: "Pay", else: "Save card"}
        </button>
      </div>
      <form
        :if={@intent.status in [:requires_payment_method, :requires_confirmation]}
        id={"card-#{@kind}-server-form"}
        phx-change="pick_test_method"
        phx-submit="confirm_server"
        phx-target={@myself}
        class="join"
        data-testid={"card-#{@kind}-server-form"}
      >
        <input type="hidden" name="kind" value={@kind} />
        <select
          name="payment_method"
          class="select select-sm join-item"
          data-testid={"card-#{@kind}-test-method"}
        >
          <option :for={{id, label} <- @test_methods} value={id} selected={id == @test_method}>
            {label}
          </option>
        </select>
        <button class="btn btn-sm join-item" data-testid={"card-#{@kind}-confirm-server"}>
          Confirm on the server
        </button>
      </form>
      <div class="flex gap-2">
        <button
          class="btn btn-xs btn-ghost"
          phx-click="read"
          phx-value-kind={@kind}
          phx-target={@myself}
          data-testid={"card-#{@kind}-read"}
        >
          Read again
        </button>
        <button
          :if={@intent.status not in [:succeeded, :canceled]}
          class="btn btn-xs btn-ghost"
          phx-click="cancel"
          phx-value-kind={@kind}
          phx-target={@myself}
          data-confirm="Cancel this intent?"
          data-testid={"card-#{@kind}-cancel"}
        >
          Cancel
        </button>
      </div>
    </div>
    """
  end
end

defmodule ShopWeb.ShopLive do
  @moduledoc """
  The demo shop's one page, on the Stripe sandbox: the place Mishka Pay is tried in action, by
  hand or by a browser test (every part carries a `data-testid`). It shows:

    * the installed providers, the site's keys and settings as Mishka Pay reads them, and every
      plugin on Mishka Pay's events;
    * the products (from the seeds) and a checkout with its options, through the site's gate;
    * the payments with totals by status, a status filter, and each payment's full details: the
      stored row beside the payment read live from Stripe (buyer, card, receipt, failure, metadata,
      refunds), its webhook events, sync and refund;
    * the customers: register one on Stripe, find and keep one, edit it, open its customer portal,
      and buy as that customer; the portal's setups on Stripe, and the portal opened with one;
    * the catalog: the shop's products published to Stripe as products and prices, sold by price
      id, and every Stripe list read page by page;
    * payment links for catalog prices, with every limit a developer can choose, and one buyer's
      address; invoices for one-time checkouts; the site's Stripe Tax setting; tax rates set by
      hand, tax registrations and Stripe Tax's settings;
    * disputes: read from Stripe or by webhook, answered with evidence or accepted; every change
      reaches the page through Mishka Pay's own PubSub plugin (`Shop.Pay.Broadcast`); Radar's
      early fraud warnings and the reviews it holds, approved from the page;
    * coupons and promotion codes, and every checkout option: discounts or typed codes, Stripe
      Tax, page language, expiry, billing address, tax ids, customer creation; a checkout held on
      the page, then paid or ended;
    * members and access by subscription, refunds and held payments, more checkout options
      (embedded too), a card form of the shop's own (Stripe Elements: a payment intent, or a
      setup intent that saves a card), saved cards and portal links, one-off bills, customer search and bill
      previews, each in its own component;
    * Stripe Connect: the shop as a platform that makes its sellers' connected accounts, opens
      their onboarding pages, sends them money and takes it back, and lists its payouts and its
      cut of their sales;
    * reading a checkout or a payment back by its id, and a raw call to any Stripe API path;
    * a webhook simulator, the webhook inbox and every telemetry event, live;
    * the site settings, read again on the next call.
  """

  use ShopWeb, :live_view

  require Ash.Query

  import ShopWeb.PayComponents

  alias Shop.Pay.{
    Payment,
    Setting,
    Stats,
    TelemetryFeed,
    WebhookEvent,
    WebhookSimulator
  }

  @tenant "demo"

  # The most of one product a demo checkout sells, so a typo never opens Stripe for thousands.
  @max_quantity 10
  @refund_form %{"amount" => "", "reason" => ""}

  @settings_topic "pay:settings"

  # Newest made at Stripe first: a payment synced again keeps its place.
  @newest_first [provider_created_at: :desc_nils_last, inserted_at: :desc]

  @statuses ~w(paid partially_refunded refunded pending requires_action failed canceled)

  # The kinds a site manages from its admin (`ShopWeb.AdminRowsComponent`).
  @admin_kinds MishkaPay.Ash.Object.Spec.kinds()

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      # Mishka Pay's own PubSub plugin (Shop.Pay.Broadcast): this site's changes only.
      for kind <- MishkaPay.PubSub.kinds(),
          do: Phoenix.PubSub.subscribe(Shop.PubSub, MishkaPay.PubSub.topic(kind, @tenant))

      Phoenix.PubSub.subscribe(Shop.PubSub, TelemetryFeed.topic())
      Phoenix.PubSub.subscribe(Shop.PubSub, @settings_topic)
      ShopWeb.Endpoint.subscribe("pay:inbox")
    end

    payments = payments("all")

    {:ok,
     socket
     |> assign(page_title: "Mishka Pay demo shop", tenant: @tenant, statuses: @statuses)
     |> assign(member: member(session["member_id"]))
     |> assign(products: Shop.Catalog.all(), names: Shop.Catalog.names())
     |> assign(selected: nil, checkout_read: nil, simulated: nil, simulate_form: %{}, buyer: nil)
     |> assign(lookup: nil, typed: %{}, lookup_failure: nil, refund_form: @refund_form)
     |> assign(checkout_lookup: nil)
     |> assign(
       filter: "all",
       max_quantity: @max_quantity,
       simulator_types: WebhookSimulator.types(),
       simulator_situations: WebhookSimulator.situations()
     )
     |> assign_status()
     |> assign_stats()
     |> assign_last()
     |> stream(:payments, payments)
     |> stream(:inbox, newest_rows(WebhookEvent))
     |> stream(:telemetry, [], limit: 40)}
  end

  @impl true
  # A buyer picked with "Buy as this customer" comes back in the URL: the shop keeps buying as them,
  # and reads their customer again, since Stripe's page may have changed it (the name on the card).
  def handle_params(%{"session_id" => session_id} = params, _uri, socket) do
    case connected?(socket) do
      true ->
        {:noreply,
         socket
         |> back_from_checkout("stripe", session_id)
         |> refresh_buyer(params["buyer"])
         |> push_patch(to: home(params["buyer"]))}

      false ->
        {:noreply, socket}
    end
  end

  # PayPal sends the buyer back with the subscription id in `subscription_id` (its `token` is not
  # the subscription), or for a payment with the Order id in `token`.
  def handle_params(%{"provider" => "paypal", "subscription_id" => subscription_id}, _uri, socket) do
    case connected?(socket) do
      true ->
        {:noreply,
         socket |> back_from_checkout("paypal", subscription_id) |> push_patch(to: ~p"/")}

      false ->
        {:noreply, socket}
    end
  end

  def handle_params(%{"provider" => "paypal", "token" => order_id}, _uri, socket) do
    case connected?(socket) do
      true ->
        {:noreply, socket |> back_from_checkout("paypal", order_id) |> push_patch(to: ~p"/")}

      false ->
        {:noreply, socket}
    end
  end

  def handle_params(%{"canceled" => _}, _uri, socket) do
    case connected?(socket) do
      true ->
        {:noreply,
         socket
         |> flash(:error, "The checkout was canceled. Nothing was charged.")
         |> push_patch(to: ~p"/")}

      false ->
        {:noreply, socket}
    end
  end

  def handle_params(%{"portal" => "back"} = params, _uri, socket) do
    case connected?(socket) do
      true ->
        {:noreply,
         socket
         |> flash(:info, "Back from the customer portal. Changes there come in by webhook.")
         |> push_patch(to: home(params["buyer"]))}

      false ->
        {:noreply, socket}
    end
  end

  # The buyer picked with "Buy as this customer" and a checkout held on the page live in the URL,
  # so a reload keeps both.
  def handle_params(params, _uri, socket) do
    held = if connected?(socket), do: params["held"]
    {:noreply, socket |> held(held) |> chosen_buyer(params["buyer"])}
  end

  @impl true
  def handle_event("buy", %{"product" => slug} = params, socket) do
    with %{} = product <- Shop.Catalog.fetch(slug),
         {:ok, count} <- quantity(params["quantity"]),
         :ok <- discount_given(params),
         {:ok, checkout} <- start_checkout(product, count, params) do
      {:noreply, go_or_hold(socket, checkout, params)}
    else
      nil -> {:noreply, flash(socket, :error, "That product is not on sale.")}
      {:error, error} -> {:noreply, flash(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("clear_buyer", _params, socket), do: {:noreply, push_patch(socket, to: ~p"/")}

  def handle_event("select", %{"id" => id}, socket),
    do: {:noreply, socket |> assign(refund_form: @refund_form) |> select(id)}

  def handle_event("close", _params, socket),
    do: {:noreply, assign(socket, selected: nil, refund_form: @refund_form)}

  # The refund typed is kept, so a webhook that updates the open payment does not reset it.
  def handle_event("draft_refund", params, socket),
    do: {:noreply, assign(socket, refund_form: refund_form(params))}

  def handle_event("filter", %{"status" => status}, socket) when status in ["all" | @statuses] do
    {:noreply,
     socket |> assign(filter: status) |> stream(:payments, payments(status), reset: true)}
  end

  def handle_event("refund", %{"payment" => id} = params, socket) do
    socket = assign(socket, refund_form: refund_form(params))

    with {:ok, payment} <- Ash.get(Payment, id, authorize?: false),
         {:ok, refunded} <-
           payment
           |> Ash.Changeset.for_update(:refund, refund_args(payment, params))
           |> Ash.update(authorize?: false) do
      {:noreply,
       socket
       |> put_payment(refunded)
       |> assign_last()
       |> assign(refund_form: @refund_form)
       |> select(refunded.id, refunded.__metadata__.refund)
       |> flash(
         :info,
         "Refunded. #{MishkaPay.Provider.label_of(payment.provider)} gives the money back to the buyer."
       )}
    else
      {:error, error} -> {:noreply, flash(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  # A payment intent no one paid is canceled on Stripe, then read back and saved, so the row and the
  # panel show it ended.
  def handle_event("cancel_payment", %{"payment" => id}, socket) do
    with {:ok, row} <- Ash.get(Payment, id, authorize?: false),
         {:ok, _intent} <-
           MishkaPay.cancel_payment_intent(row.provider, row.provider_id, row.tenant),
         {:ok, payment} <- sync(row.provider_id) do
      {:noreply,
       socket
       |> put_payment(payment)
       |> select(payment.id)
       |> flash(:info, "Payment canceled: it can no longer be paid.")}
    else
      {:error, error} -> {:noreply, flash(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  # What is typed in the buy form and the payment box is kept, so both come back as they were
  # after a reconnect (LiveView sends them again as these changes).
  def handle_event("typed", params, socket) do
    typed = Map.reject(params, fn {name, _value} -> String.starts_with?(name, "_") end)
    {:noreply, assign(socket, typed: typed)}
  end

  def handle_event("lookup", %{"payment_id" => value}, socket),
    do: {:noreply, assign(socket, lookup: value)}

  def handle_event("sync", %{"payment_id" => payment_id}, socket) do
    with {:ok, payment_id} <- payment_id(payment_id),
         {:ok, payment} <- sync(payment_id) do
      {:noreply,
       socket
       |> put_payment(payment)
       |> assign(lookup: nil, lookup_failure: nil)
       |> assign_last()
       |> select(payment.id)
       |> flash(
         :info,
         "Payment read from #{MishkaPay.Provider.label_of(payment.provider)} and saved."
       )}
    else
      {:error, error} ->
        {:noreply,
         socket
         |> close_other(payment_id)
         |> assign(lookup: payment_id, lookup_failure: MishkaPay.Ash.provider_error(error))
         |> flash(:error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("expire_checkout", %{"id" => checkout_id}, socket) do
    case MishkaPay.expire_checkout(provider_of(checkout_id), checkout_id, @tenant) do
      {:ok, checkout} ->
        {:noreply,
         socket
         |> assign(checkout_read: checkout)
         |> flash(:info, "Checkout ended. Its page no longer takes payment.")}

      {:error, error} ->
        {:noreply, flash(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  # What is typed stays through the page's live updates and a reconnect.
  def handle_event("checkout_lookup", %{"checkout_id" => value}, socket),
    do: {:noreply, assign(socket, checkout_lookup: value)}

  def handle_event("read_checkout", %{"checkout_id" => checkout_id}, socket) do
    with {:ok, checkout_id} <- checkout_id(checkout_id),
         {:ok, checkout} <-
           MishkaPay.fetch_checkout(provider_of(checkout_id), checkout_id, @tenant) do
      {:noreply, socket |> clear_flash() |> assign(checkout_read: checkout)}
    else
      {:error, error} ->
        {:noreply,
         socket |> assign(checkout_read: nil) |> flash(:error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("simulate", %{"payment_id" => payment_id, "type" => type} = params, socket) do
    socket =
      assign(socket,
        simulated: nil,
        simulate_form: %{payment_id: payment_id, type: type, situation: params["situation"]}
      )

    with {:ok, payment_id} <- object_id(payment_id),
         true <- type in WebhookSimulator.types(),
         :ok <- id_matches_type(payment_id, type),
         {:ok, situation, spec} <- situation(params["situation"]) do
      {statuses, event_id} = WebhookSimulator.send_event(payment_id, type, @tenant, situation)

      {:noreply,
       socket
       |> clear_flash()
       |> assign(
         simulated: %{
           statuses: statuses,
           expect: spec.expect,
           event_id: event_id,
           type: type,
           situation: situation,
           label: spec.label
         }
       )}
    else
      false -> {:noreply, flash(socket, :error, "Choose an event type from the list.")}
      {:error, error} -> {:noreply, flash(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("save_settings", params, socket) do
    attrs = %{
      tenant: @tenant,
      refunds: params["refunds"],
      merchant_of_record: on_off(params["merchant_of_record"]),
      automatic_tax: params["automatic_tax"] == "true",
      open: params["open"] == "true"
    }

    case Ash.create(Setting, attrs, action: :save, authorize?: false) do
      {:ok, _setting} ->
        Phoenix.PubSub.broadcast_from(Shop.PubSub, self(), @settings_topic, :settings_changed)

        {:noreply,
         socket
         |> assign_status()
         |> flash(:info, "Saved. The next checkout or refund uses it, no restart.")}

      {:error, error} ->
        {:noreply, flash(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  @impl true
  def handle_info({:mishka_pay, :payment, %{record: record}}, socket) do
    send_update(ShopWeb.PaymentToolsComponent, id: "payment-tools", changed: record)

    {:noreply,
     socket
     |> put_payment(record)
     |> assign_last()
     |> reselect(record)}
  end

  def handle_info(:settings_changed, socket), do: {:noreply, assign_status(socket)}

  def handle_info({:mishka_pay, :subscription, %{record: record}}, socket) do
    send_update(ShopWeb.SubscriptionsComponent, id: "subscriptions", changed: record)
    send_update(ShopWeb.AccessComponent, id: "access", changed: record)
    {:noreply, socket}
  end

  # A message from the subscriptions part, shown like the page's own.
  def handle_info({:mishka_pay, :customer, %{record: record}}, socket) do
    send_update(ShopWeb.CustomersComponent, id: "customers", changed: record)
    {:noreply, assign(socket, buyer: same_buyer(socket.assigns.buyer, record))}
  end

  def handle_info({:mishka_pay, :dispute, %{record: record}}, socket) do
    send_update(ShopWeb.DisputesComponent, id: "disputes", changed: record)
    {:noreply, socket}
  end

  # What the site manages from its admin: products, prices, coupons, codes, links and bills.
  def handle_info({:mishka_pay, kind, %{record: record}}, socket)
      when kind in @admin_kinds do
    send_update(ShopWeb.AdminRowsComponent, id: "admin-rows", changed: {kind, record})
    {:noreply, socket}
  end

  def handle_info({:buyer, customer}, socket) do
    {:noreply,
     socket
     |> push_patch(to: ~p"/?buyer=#{customer.id}")
     |> flash(
       :info,
       "Buying as #{customer.name || customer.email}. Press Buy on a product or plan below to pay as them."
     )}
  end

  def handle_info(:catalog_published, socket),
    do: {:noreply, assign(socket, products: Shop.Catalog.all())}

  def handle_info({:flash, kind, message}, socket), do: {:noreply, flash(socket, kind, message)}

  def handle_info({:telemetry, entry}, socket),
    do: {:noreply, stream_insert(socket, :telemetry, entry, at: 0)}

  def handle_info(%Phoenix.Socket.Broadcast{topic: "pay:inbox", payload: notification}, socket),
    do: {:noreply, stream_insert(socket, :inbox, notification.data, at: 0)}

  @impl true
  def handle_async(:checkout_back, {:ok, {:ok, checkout, kept}}, socket),
    do: {:noreply, socket |> assign(checkout_read: checkout) |> kept(kept)}

  def handle_async(:checkout_back, {:ok, {:error, error}}, socket),
    do: {:noreply, flash(socket, :error, MishkaPay.Ash.message(error))}

  def handle_async(:checkout_back, {:exit, reason}, socket),
    do: {:noreply, flash(socket, :error, "The payment could not be read: #{inspect(reason)}")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.link
        navigate={~p"/sell"}
        class="card bg-primary/10 border border-primary/40 hover:bg-primary/20 mb-6"
        data-testid="sell-page-link"
      >
        <div class="card-body flex-row items-center gap-4 py-4">
          <.icon name="hero-bolt" class="size-8 text-primary" />
          <div class="flex-1">
            <div class="font-semibold">Sell a product with one link</div>
            <div class="text-sm opacity-70">
              Fill in a product, press one button: Mishka Pay makes it, its price and a payment link
              at Stripe, shows each step, and gives you the link buyers pay with. Undo takes it all back.
            </div>
          </div>
          <.icon name="hero-arrow-right" class="size-5" />
        </div>
      </.link>
      <.status
        providers={@providers}
        keys={@keys}
        setting={@setting}
        tenant={@tenant}
        plugins={@plugins}
        local_webhook_secret?={@local_webhook_secret?}
        paypal?={@paypal?}
      />

      <section data-testid="buy">
        <.section_title icon="hero-shopping-cart" title="Buy something" />
        <form id="buy" phx-change="typed" phx-submit="buy" class="group/buy space-y-4">
          <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3" data-testid="one-time-products">
            <.product
              :for={product <- @products}
              :if={!Shop.Catalog.plan?(product)}
              product={product}
              open?={@setting.open}
            />
          </div>
          <h3 class="font-medium flex items-center gap-2">
            Plans
            <span class="text-sm font-normal opacity-60">charged again on a schedule, as a subscription</span>
          </h3>
          <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3" data-testid="plans">
            <.product
              :for={product <- @products}
              :if={Shop.Catalog.plan?(product)}
              product={product}
              open?={@setting.open}
            />
          </div>
          <.buyer_bar :if={@buyer} buyer={@buyer} />
          <.checkout_options
            max_quantity={@max_quantity}
            paypal?={@paypal?}
            buyer?={!!@buyer}
            typed={@typed}
          />
        </form>
        <.test_cards />
      </section>

      <.last_bought :if={@last} payment={@last} names={@names} />

      <section data-testid="payments">
        <div class="flex flex-wrap items-end justify-between gap-3 mb-3">
          <.section_title icon="hero-banknotes" title="Payments" />
          <form
            id="read-payment-form"
            phx-change="lookup"
            phx-submit="sync"
            class="join"
            data-testid="read-payment-form"
          >
            <input
              name="payment_id"
              value={@lookup}
              placeholder="pi_... or a PayPal order id"
              class="input input-sm join-item"
              data-testid="read-payment-input"
            />
            <button class="btn btn-sm join-item" data-testid="read-payment-submit">
              Read payment
            </button>
          </form>
        </div>
        <.request_id :if={@lookup_failure} error={@lookup_failure} />
        <.stats stats={@stats} filter={@filter} statuses={@statuses} />
        <.payments_table payments={@streams.payments} names={@names} />
      </section>

      <.payment_details
        :if={@selected}
        selected={@selected}
        live={@live}
        names={@names}
        refund_form={@refund_form}
      />

      <.live_component module={ShopWeb.SubscriptionsComponent} id="subscriptions" tenant={@tenant} />

      <.live_component
        module={ShopWeb.CustomersComponent}
        id="customers"
        tenant={@tenant}
        buyer={@buyer}
      />

      <.live_component module={ShopWeb.PortalConfigsComponent} id="portal-configs" tenant={@tenant} />

      <.live_component module={ShopWeb.DiscountsComponent} id="discounts" tenant={@tenant} />

      <.live_component module={ShopWeb.DisputesComponent} id="disputes" tenant={@tenant} />

      <.live_component module={ShopWeb.FraudComponent} id="fraud" tenant={@tenant} />

      <.live_component module={ShopWeb.CatalogComponent} id="catalog" tenant={@tenant} />

      <.live_component module={ShopWeb.PaymentLinksComponent} id="payment-links" tenant={@tenant} />

      <.live_component module={ShopWeb.StripeListsComponent} id="stripe-lists" tenant={@tenant} />

      <.live_component module={ShopWeb.TestClocksComponent} id="clocks" tenant={@tenant} />

      <.live_component module={ShopWeb.AdminRowsComponent} id="admin-rows" tenant={@tenant} />

      <.live_component module={ShopWeb.FilesComponent} id="files" tenant={@tenant} />

      <.live_component module={ShopWeb.TaxComponent} id="tax" tenant={@tenant} />

      <.live_component module={ShopWeb.TaxSetupComponent} id="tax-setup" tenant={@tenant} />

      <.live_component module={ShopWeb.UsageComponent} id="usage" tenant={@tenant} />

      <.live_component module={ShopWeb.EntitlementsComponent} id="entitlements" tenant={@tenant} />

      <.live_component module={ShopWeb.BalanceComponent} id="balance" tenant={@tenant} />

      <.live_component module={ShopWeb.ConnectComponent} id="connect" tenant={@tenant} />

      <.live_component module={ShopWeb.OperationsComponent} id="operations" tenant={@tenant} />

      <.live_component module={ShopWeb.CurrenciesComponent} id="currencies" tenant={@tenant} />

      <.live_component module={ShopWeb.AccessComponent} id="access" tenant={@tenant} member={@member} />

      <.live_component module={ShopWeb.PaymentToolsComponent} id="payment-tools" tenant={@tenant} />

      <.live_component module={ShopWeb.CheckoutOptionsComponent} id="checkout-more" tenant={@tenant} />

      <.live_component module={ShopWeb.CardFormComponent} id="card-form" tenant={@tenant} />

      <.live_component module={ShopWeb.SavedCardsComponent} id="saved-cards" tenant={@tenant} />

      <.live_component module={ShopWeb.BillsComponent} id="bills" tenant={@tenant} />

      <.live_component module={ShopWeb.LookupsComponent} id="lookups" tenant={@tenant} />

      <.live_component module={ShopWeb.RawCallComponent} id="raw-call" tenant={@tenant} />

      <section data-testid="read-checkout">
        <.section_title icon="hero-magnifying-glass" title="Read a checkout back" />
        <form
          id="read-checkout-form"
          phx-change="checkout_lookup"
          phx-submit="read_checkout"
          class="join w-full max-w-2xl"
          data-testid="read-checkout-form"
        >
          <input
            name="checkout_id"
            value={@checkout_lookup}
            placeholder="cs_test_... (shown after each purchase)"
            class="input input-sm join-item min-w-0 flex-1"
            data-testid="read-checkout-input"
          />
          <button class="btn btn-sm join-item shrink-0" data-testid="read-checkout-submit">
            Read
          </button>
        </form>
        <.checkout_card :if={@checkout_read} checkout={@checkout_read} />
      </section>

      <.webhook_simulator
        types={@simulator_types}
        situations={@simulator_situations}
        simulated={@simulated}
        form={@simulate_form}
        tenant={@tenant}
        local_webhook_secret?={@local_webhook_secret?}
      />

      <div class="grid gap-8 lg:grid-cols-2">
        <section class="min-w-0" data-testid="inbox">
          <.section_title icon="hero-inbox-arrow-down" title="Webhook inbox" />
          <.inbox_table events={@streams.inbox} />
        </section>
        <section class="min-w-0" data-testid="telemetry">
          <.section_title icon="hero-signal" title="Telemetry, live" />
          <.telemetry_log entries={@streams.telemetry} />
        </section>
      </div>

      <.settings_form setting={@setting} tenant={@tenant} />
    </Layouts.app>
    """
  end

  defp start_checkout(product, count, params) do
    Payment
    |> Ash.ActionInput.for_action(:start_checkout, %{checkout: checkout(product, count, params)})
    |> Ash.run_action(authorize?: false)
  end

  # A plan opens a subscription checkout, with its interval and trial; any other product is paid
  # once.
  defp checkout(product, count, params) do
    provider = provider_choice(params["provider"])

    %{
      provider: provider,
      tenant: @tenant,
      mode: if(Shop.Catalog.plan?(product), do: :subscription, else: :payment),
      trial_days: product.trial_days,
      items: [item(provider, product, count)],
      success_url: success_url(provider, params["buyer"]),
      cancel_url: url(~p"/?canceled=1"),
      reference: Shop.Catalog.reference(product),
      customer: buyer(params),
      metadata: metadata(params["meta_key"], params["meta_value"])
    }
    |> Map.merge(options(provider, params))
  end

  # A product published to Stripe's catalog sells its Stripe price by id with Stripe; one not
  # published yet, or sold with PayPal (which has no Stripe catalog), sends its name, amount and
  # schedule.
  defp item("stripe", %{stripe_price_id: price_id}, count) when is_binary(price_id),
    do: %{id: price_id, quantity: count}

  defp item(_provider, product, count) do
    %{
      name: product.name,
      amount: %{amount: product.price, currency: "USD"},
      tax_code: product.tax_code,
      quantity: count,
      interval: product.interval,
      interval_count: product.interval && product.interval_count
    }
  end

  # "Open it here" keeps the buyer on the shop with the checkout shown, to pay or end later; the
  # held checkout goes in the URL so a reload still shows it.
  defp go_or_hold(socket, checkout, %{"hold" => "true"} = params) do
    query =
      Map.reject(%{held: checkout.id, buyer: blank_nil(params["buyer"])}, &is_nil(elem(&1, 1)))

    socket
    |> assign(checkout_read: checkout)
    |> push_patch(to: ~p"/?#{query}")
    |> flash(:info, "Checkout opened and held. Pay it from its card below, or end it.")
  end

  defp go_or_hold(socket, %{url: url}, _go), do: redirect(socket, external: url)

  defp held(socket, id) when id in [nil, ""], do: socket

  defp held(%{assigns: %{checkout_read: %{id: id}}} = socket, id), do: socket

  defp held(socket, id) do
    case MishkaPay.fetch_checkout(provider_of(id), id, @tenant) do
      {:ok, checkout} -> assign(socket, checkout_read: checkout)
      {:error, _gone} -> socket
    end
  end

  # The member signed in by email (ShopWeb.MemberController); a member gone from the table is
  # nobody.
  defp member(nil), do: nil

  defp member(id) do
    case Ash.get(Shop.Accounts.Member, id, authorize?: false) do
      {:ok, member} -> member
      {:error, _gone} -> nil
    end
  end

  defp chosen_buyer(socket, id) when id in [nil, ""], do: assign(socket, buyer: nil)

  defp chosen_buyer(socket, id) do
    case Ash.get(Shop.Pay.Customer, id, authorize?: false) do
      {:ok, %{deleted_at: nil} = customer} -> assign(socket, buyer: customer)
      _gone -> socket |> assign(buyer: nil) |> push_patch(to: ~p"/")
    end
  end

  # Applying a code or a coupon needs its id; leaving it empty would sell at full price.
  defp discount_given(%{"discount_mode" => mode} = params) when mode in ["code", "coupon"] do
    case blank_nil(params["discount_id"]) do
      nil ->
        {:error,
         "Type the #{if mode == "code", do: "promotion code's id (promo_...)", else: "coupon's id"} to apply, or pick no discount."}

      _id ->
        :ok
    end
  end

  defp discount_given(_params), do: :ok

  # The checkout options, each only when chosen; Mishka Pay refuses a wrong mix with a reason.
  # Stripe's options; the form hides them under PayPal, and anything left in them is not sent.
  defp options("paypal", _params), do: %{}

  defp options("stripe", params) do
    %{
      merchant_of_record: on_off(params["merchant_of_record"]),
      discounts: discounts(params["discount_mode"], blank_nil(params["discount_id"])),
      allow_promotion_codes: (params["discount_mode"] == "typed" && true) || nil,
      automatic_tax: on_off(params["automatic_tax"]),
      invoice: (params["invoice"] == "true" && true) || nil,
      tax_id_collection: (params["tax_id_collection"] == "true" && true) || nil,
      locale: blank_nil(params["locale"]),
      billing_address: blank_nil(params["billing_address"]),
      customer_creation: blank_nil(params["customer_creation"]),
      expires_at: expires_at(blank_nil(params["expires_in"]))
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp discounts("code", id) when is_binary(id), do: [%{promotion_code_id: id}]
  defp discounts("coupon", id) when is_binary(id), do: [%{coupon_id: id}]
  defp discounts(_none, _id), do: nil

  # Minutes from now; a number that is not one is left for Stripe's default.
  defp expires_at(nil), do: nil

  defp expires_at(minutes) do
    case Integer.parse(minutes) do
      {count, ""} -> DateTime.add(DateTime.utc_now(), count * 60)
      _not_a_number -> nil
    end
  end

  # A customer picked with "Buy as this customer" pays as that Stripe customer; otherwise the
  # email typed, if any, fills Stripe's page.
  defp buyer(%{"customer_id" => id}) when id != "", do: %{id: id}
  defp buyer(params), do: blank_nil(params["email"]) && %{email: params["email"]}

  # A customer deleted on Stripe stops being the buyer; an edited one keeps buying, as it is now.
  defp same_buyer(%{id: id}, %{id: id, deleted_at: nil} = record), do: record
  defp same_buyer(%{id: id}, %{id: id}), do: nil
  defp same_buyer(buyer, _other), do: buyer

  # The buyer comes back from the provider's page: the checkout is read (PayPal captures the Order
  # here, which takes seconds) and its payment kept at once rather than waiting for the webhook. It
  # runs in the background, so the page connects and says what it is doing meanwhile.
  defp back_from_checkout(socket, provider, checkout_id) do
    socket
    |> flash(:info, "Confirming your payment with #{MishkaPay.Provider.label_of(provider)}...")
    |> start_async(:checkout_back, fn -> checkout_back(provider, checkout_id) end)
  end

  defp checkout_back(provider, checkout_id) do
    with {:ok, checkout} <- MishkaPay.fetch_checkout(provider, checkout_id, @tenant) do
      {:ok, checkout, keep(provider, checkout)}
    end
  end

  defp keep(provider, %{subscription_id: id}) when is_binary(id) do
    {:subscription,
     Ash.create(
       Shop.Pay.Subscription,
       %{provider: provider, subscription_id: id, tenant: @tenant},
       action: :sync,
       authorize?: false
     )}
  end

  defp keep(_provider, %{payment_id: id}) when is_binary(id), do: {:payment, sync(id)}
  defp keep(_provider, %{setup_intent_id: id}) when is_binary(id), do: :card_saved
  defp keep(provider, _checkout), do: {:later, provider}

  defp kept(socket, {:subscription, {:ok, subscription}}) do
    send_update(ShopWeb.SubscriptionsComponent, id: "subscriptions", changed: subscription)
    send_update(ShopWeb.SubscriptionsComponent, id: "subscriptions", open: subscription.id)
    flash(socket, :info, "Thank you! Your subscription is below, with its invoices.")
  end

  defp kept(socket, {:payment, {:ok, payment}}) do
    socket
    |> put_payment(payment)
    |> assign_last()
    |> select(payment.id)
    |> flash(:info, "Thank you! Your payment is below, with its details.")
  end

  defp kept(socket, {_kind, {:error, error}}),
    do: flash(socket, :error, MishkaPay.Ash.message(error))

  defp kept(socket, :card_saved),
    do: flash(socket, :info, "Card saved. List the customer's cards under Saved cards.")

  defp kept(socket, {:later, provider}) do
    label = MishkaPay.Provider.label_of(provider)
    flash(socket, :info, "Thank you! The payment shows once #{label} confirms it.")
  end

  # A changed payment: the table read again in its own order (newest made at Stripe first, so a
  # payment synced again keeps its place) when it fits the filter, and the totals counted again.
  # A payment the filter does not show leaves the table untouched.
  defp put_payment(socket, record) do
    socket =
      case socket.assigns.filter in ["all", to_string(record.status)] do
        true -> stream(socket, :payments, payments(socket.assigns.filter), reset: true)
        false -> stream_delete(socket, :payments, record)
      end

    assign_stats(socket)
  end

  # A failed read of another payment closes the panel: it must not look like the answer.
  defp close_other(%{assigns: %{selected: %{payment: %{provider_id: id}}}} = socket, id),
    do: socket

  defp close_other(socket, _payment_id), do: assign(socket, selected: nil)

  defp refund_form(params), do: Map.merge(@refund_form, Map.take(params, Map.keys(@refund_form)))

  # One payment in the details panel: its row and webhook events from the database now, and the
  # payment as Stripe has it, read in the background.
  defp select(socket, id, refund \\ nil) do
    payment = Ash.get!(Payment, id, load: [:money, :money_refunded], authorize?: false)

    events =
      WebhookEvent
      |> Ash.Query.filter(payment_id == ^payment.provider_id)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(authorize?: false)

    socket
    |> assign(selected: %{payment: payment, events: events, refund: refund})
    |> assign_async(
      :live,
      fn ->
        case MishkaPay.fetch_payment(payment.provider, payment.provider_id, payment.tenant) do
          {:ok, live} -> {:ok, %{live: live}}
          {:error, error} -> {:error, MishkaPay.Ash.message(error)}
        end
      end,
      reset: true
    )
  end

  # The open panel follows a change made elsewhere (another tab, a webhook), keeping its last refund.
  defp reselect(%{assigns: %{selected: %{payment: %{id: id}, refund: refund}}} = socket, %{id: id}),
       do: select(socket, id, refund)

  defp reselect(socket, _other_payment), do: socket

  defp sync(payment_id) do
    Ash.create(
      Payment,
      %{provider: provider_of(payment_id), payment_id: payment_id, tenant: @tenant},
      action: :sync,
      authorize?: false
    )
  end

  # A site that refunds many times names each refund; the demo names it on the click. A real shop
  # would use the id of its own refund record.
  defp refund_args(payment, params) do
    args = %{reference: "refund-" <> Ecto.UUID.generate(), reason: blank_nil(params["reason"])}

    case blank_nil(params["amount"]) do
      nil -> args
      amount -> Map.put(args, :amount, %{amount: amount, currency: payment.currency})
    end
  end

  defp assign_status(socket) do
    keys =
      case MishkaPay.Credentials.fetch("stripe", @tenant) do
        {:ok, keys} -> keys
        {:error, _missing} -> nil
      end

    plugins =
      for plugin <- MishkaInstaller.Event.Event.get(),
          String.starts_with?(plugin.event, "mishka_pay:"),
          do: plugin

    assign(socket,
      paypal?: match?({:ok, _keys}, MishkaPay.Credentials.fetch("paypal", @tenant)),
      providers: MishkaPay.Provider.all(),
      keys: keys,
      setting: setting(),
      plugins: Enum.sort_by(plugins, &{&1.event, &1.priority}),
      local_webhook_secret?: Shop.Pay.Keys.local_webhook_secret?()
    )
  end

  defp assign_stats(socket), do: assign(socket, stats: Stats.by_status())

  # "Last bought" is the newest payment that took money, whatever the filter shows.
  defp assign_last(socket) do
    last =
      Payment
      |> Ash.Query.filter(status in [:paid, :partially_refunded, :refunded])
      |> Ash.Query.sort(@newest_first)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(authorize?: false)

    assign(socket, last: last)
  end

  defp payments(status) do
    Payment
    |> filter_status(status)
    |> Ash.Query.sort(@newest_first)
    |> Ash.Query.limit(50)
    |> Ash.read!(authorize?: false)
  end

  defp filter_status(query, "all"), do: query

  defp filter_status(query, status) do
    status = String.to_existing_atom(status)
    Ash.Query.filter(query, status == ^status)
  end

  defp newest_rows(resource) do
    resource
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(30)
    |> Ash.read!(authorize?: false)
  end

  defp setting do
    Setting
    |> Ash.Query.filter(tenant == ^@tenant)
    |> Ash.read_one!(authorize?: false)
    |> Kernel.||(%Setting{tenant: @tenant, refunds: :once, open: true})
  end

  # One message at a time: a new answer replaces the last one, whatever its kind.
  defp flash(socket, kind, message), do: socket |> clear_flash() |> put_flash(kind, message)

  defp quantity(value) do
    case Integer.parse(String.trim(value || "")) do
      {count, ""} when count in 1..@max_quantity//1 -> {:ok, count}
      _not_one_to_max -> {:error, "Quantity must be a whole number from 1 to #{@max_quantity}."}
    end
  end

  defp payment_id(value) do
    case blank_nil(value) do
      nil -> {:error, "Type a payment id first: pi_... (Stripe) or a PayPal order id."}
      "cs_" <> _ -> {:error, ~s|That is a checkout id (cs_). Use "Read a checkout back" below.|}
      "pi_" <> _ = id -> {:ok, id}
      id -> paypal_order_id(id)
    end
  end

  # Anything not a Stripe pi_ id is read from PayPal, whose order ids are letters and digits.
  defp paypal_order_id(id) do
    case Regex.match?(~r/\A[A-Z0-9]{6,40}\z/, id) do
      true -> {:ok, id}
      false -> {:error, "That is not a payment id: pi_... (Stripe) or a PayPal order id."}
    end
  end

  # Stripe sends payment_intent.* and charge.refunded about a pi_ id, subscription and invoice
  # events about a sub_ id. A well-formed id that does not exist (pi_nope) still goes through: it
  # shows the inbox retry path.
  defp id_matches_type(id, "payment_intent." <> _),
    do: expect_prefix(id, "pi_", "payment_intent.*")

  defp id_matches_type(id, "charge.refunded"), do: expect_prefix(id, "pi_", "charge.refunded")

  defp id_matches_type(id, "customer.subscription." <> _),
    do: expect_prefix(id, "sub_", "customer.subscription.*")

  defp id_matches_type(id, "invoice." <> _), do: expect_prefix(id, "sub_", "invoice.*")

  defp expect_prefix(id, prefix, family) do
    case String.starts_with?(id, prefix) do
      true ->
        :ok

      false ->
        {:error, "#{family} events need a #{prefix} id: Stripe never sends them about #{id}."}
    end
  end

  defp provider_choice("paypal"), do: "paypal"
  defp provider_choice(_stripe), do: "stripe"

  # Stripe sends the buyer back with the session id in the URL; PayPal adds its own `token`.
  defp success_url("stripe", buyer),
    do: url(~p"/") <> "?session_id={CHECKOUT_SESSION_ID}" <> buyer_param(buyer)

  defp success_url("paypal", _buyer), do: url(~p"/?provider=paypal")

  defp buyer_param(buyer) when buyer in [nil, ""], do: ""
  defp buyer_param(buyer), do: "&" <> URI.encode_query(buyer: buyer)

  defp home(buyer) when buyer in [nil, ""], do: ~p"/"
  defp home(buyer), do: ~p"/?buyer=#{buyer}"

  defp refresh_buyer(socket, buyer) when buyer in [nil, ""], do: socket

  defp refresh_buyer(socket, buyer) do
    with {:ok, row} <- Ash.get(Shop.Pay.Customer, buyer, authorize?: false),
         {:ok, synced} <-
           Ash.create(
             Shop.Pay.Customer,
             %{provider: row.provider, customer_id: row.provider_id, tenant: row.tenant},
             action: :sync,
             authorize?: false
           ) do
      send_update(ShopWeb.CustomersComponent, id: "customers", changed: synced)
      socket
    else
      _not_found -> socket
    end
  end

  # Stripe ids carry their object's prefix; a PayPal Order id is letters and digits.
  defp provider_of("pi_" <> _), do: "stripe"
  defp provider_of("cs_" <> _), do: "stripe"
  defp provider_of(_paypal_order), do: "paypal"

  defp situation(value) do
    case Enum.find(WebhookSimulator.situations(), fn {name, _spec} ->
           Atom.to_string(name) == value
         end) do
      {name, spec} -> {:ok, name, spec}
      nil -> {:error, "Choose a situation from the list."}
    end
  end

  # The simulator takes a payment or a subscription id.
  defp object_id(value) do
    case blank_nil(value) do
      nil -> {:error, "Type a payment (pi_) or subscription (sub_) id first."}
      "cs_" <> _ -> {:error, "That is a checkout id (cs_): the simulator takes a pi_ or sub_ id."}
      id -> {:ok, id}
    end
  end

  defp checkout_id(value) do
    case blank_nil(value) do
      nil -> {:error, "Type a checkout id first, it starts with cs_."}
      "pi_" <> _ -> {:error, ~s|That is a payment id (pi_). Use "Read payment" above.|}
      id -> {:ok, id}
    end
  end

  defp metadata(key, value) do
    case blank_nil(key) do
      nil -> nil
      key -> %{key => blank_nil(value) || ""}
    end
  end

  defp on_off("on"), do: true
  defp on_off("off"), do: false
  defp on_off(_default), do: nil

  defp blank_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_nil(_none), do: nil
end

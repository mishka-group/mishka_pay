defmodule ShopWeb.ShopLive do
  @moduledoc """
  The demo shop's one page, on the Stripe sandbox. It shows every part of Mishka Pay by hand:

    * the installed providers and the site's keys and settings, as Mishka Pay reads them;
    * a checkout with its options (quantity, buyer email, merchant of record, metadata), through
      the site's checkout gate;
    * every payment, live, with its details from the database and from Stripe, its webhook events,
      sync and refund;
    * reading a checkout or a payment back by its id;
    * the webhook inbox and every telemetry event, live;
    * the site settings, read again on the next call.
  """

  use ShopWeb, :live_view

  require Ash.Query

  import ShopWeb.PayComponents

  alias Shop.Pay.{LiveFeed, Payment, Setting, TelemetryFeed, WebhookEvent}

  @tenant "demo"

  @products [
    %{id: "ebook", name: "Elixir ebook", price: "19.99", icon: "hero-book-open"},
    %{id: "course", name: "LiveView course", price: "49.00", icon: "hero-play-circle"},
    %{id: "stickers", name: "Sticker pack", price: "4.50", icon: "hero-sparkles"}
  ]

  # Stripe's tax code for digital books. The sandbox sells with Stripe Managed Payments, which
  # needs a tax code on every price.
  @tax_code "txcd_10302000"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Shop.PubSub, LiveFeed.topic())
      Phoenix.PubSub.subscribe(Shop.PubSub, TelemetryFeed.topic())
      ShopWeb.Endpoint.subscribe("pay:inbox")
    end

    payments = newest_rows(Payment)

    {:ok,
     socket
     |> assign(page_title: "Mishka Pay demo shop", products: @products, tenant: @tenant)
     |> assign(last: List.first(payments), selected: nil, checkout_read: nil)
     |> assign_status()
     |> stream(:payments, payments)
     |> stream(:inbox, newest_rows(WebhookEvent))
     |> stream(:telemetry, [], limit: 30)}
  end

  @impl true
  def handle_params(%{"session_id" => session_id}, _uri, socket) do
    case connected?(socket) do
      true -> {:noreply, socket |> back_from_checkout(session_id) |> push_patch(to: ~p"/")}
      false -> {:noreply, socket}
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

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("buy", %{"product" => id} = params, socket) do
    product = Enum.find(@products, &(&1.id == id))

    Payment
    |> Ash.ActionInput.for_action(:start_checkout, %{checkout: checkout(product, params)})
    |> Ash.run_action(authorize?: false)
    |> case do
      {:ok, %{url: url}} -> {:noreply, redirect(socket, external: url)}
      {:error, error} -> {:noreply, flash(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("select", %{"id" => id}, socket), do: {:noreply, select(socket, id)}

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, selected: nil)}

  def handle_event("refund", %{"payment" => id} = params, socket) do
    with {:ok, payment} <- Ash.get(Payment, id, authorize?: false),
         {:ok, refunded} <-
           payment
           |> Ash.Changeset.for_update(:refund, refund_args(payment, params))
           |> Ash.update(authorize?: false) do
      {:noreply,
       socket
       |> stream_insert(:payments, refunded)
       |> select(refunded.id, refunded.__metadata__.refund)
       |> flash(:info, "Refunded. Stripe gives the money back to the card.")}
    else
      {:error, error} -> {:noreply, flash(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("sync", %{"payment_id" => payment_id}, socket) do
    case sync(String.trim(payment_id)) do
      {:ok, payment} ->
        {:noreply,
         socket
         |> stream_insert(:payments, payment, at: 0)
         |> select(payment.id)
         |> flash(:info, "Payment read from Stripe and saved.")}

      {:error, error} ->
        {:noreply, flash(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("read_checkout", %{"checkout_id" => checkout_id}, socket) do
    case MishkaPay.fetch_checkout("stripe", String.trim(checkout_id), @tenant) do
      {:ok, checkout} -> {:noreply, socket |> clear_flash() |> assign(checkout_read: checkout)}
      {:error, error} -> {:noreply, flash(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("save_settings", params, socket) do
    attrs = %{
      tenant: @tenant,
      refunds: params["refunds"],
      merchant_of_record: on_off(params["merchant_of_record"]),
      open: params["open"] == "true"
    }

    case Ash.create(Setting, attrs, action: :save, authorize?: false) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> assign_status()
         |> flash(:info, "Saved. The next checkout or refund uses it, no restart.")}

      {:error, error} ->
        {:noreply, flash(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  @impl true
  def handle_info({:payment_changed, record}, socket) do
    {:noreply,
     socket
     |> stream_insert(:payments, record, at: 0)
     |> assign(last: newest(socket.assigns.last, record))}
  end

  def handle_info({:telemetry, entry}, socket),
    do: {:noreply, stream_insert(socket, :telemetry, entry, at: 0)}

  def handle_info(%Phoenix.Socket.Broadcast{topic: "pay:inbox", payload: notification}, socket),
    do: {:noreply, stream_insert(socket, :inbox, notification.data, at: 0)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.status providers={@providers} keys={@keys} setting={@setting} tenant={@tenant} />

      <section>
        <.section_title icon="hero-shopping-cart" title="Buy something" />
        <form id="buy" phx-submit="buy" class="space-y-4">
          <div class="grid gap-4 sm:grid-cols-3">
            <.product :for={product <- @products} product={product} open?={@setting.open} />
          </div>
          <.checkout_options />
        </form>
        <p class="text-sm opacity-70 mt-2">
          Test card <code>4242 4242 4242 4242</code>, any future date, any CVC.
          <code>4000 0000 0000 0002</code>
          is declined.
        </p>
      </section>

      <.last_bought :if={@last} payment={@last} />

      <section>
        <div class="flex flex-wrap items-end justify-between gap-3 mb-3">
          <.section_title icon="hero-banknotes" title="Payments" />
          <form phx-submit="sync" class="join">
            <input
              name="payment_id"
              placeholder="pi_... from the sandbox"
              class="input input-sm join-item"
              required
            />
            <button class="btn btn-sm join-item">Read payment</button>
          </form>
        </div>
        <.payments_table payments={@streams.payments} />
      </section>

      <.payment_details :if={@selected} selected={@selected} live={@live} />

      <section>
        <.section_title icon="hero-magnifying-glass" title="Read a checkout back" />
        <form phx-submit="read_checkout" class="join">
          <input
            name="checkout_id"
            placeholder="cs_test_... (shown after each purchase)"
            class="input input-sm join-item w-96"
            required
          />
          <button class="btn btn-sm join-item">MishkaPay.fetch_checkout/3</button>
        </form>
        <.checkout_card :if={@checkout_read} checkout={@checkout_read} />
      </section>

      <div class="grid gap-8 lg:grid-cols-2">
        <section>
          <.section_title icon="hero-inbox-arrow-down" title="Webhook inbox" />
          <.inbox_table events={@streams.inbox} tenant={@tenant} />
        </section>
        <section>
          <.section_title icon="hero-signal" title="Telemetry, live" />
          <.telemetry_log entries={@streams.telemetry} />
        </section>
      </div>

      <.settings_form setting={@setting} tenant={@tenant} />
    </Layouts.app>
    """
  end

  defp checkout(product, params) do
    %{
      provider: "stripe",
      tenant: @tenant,
      items: [
        %{
          name: product.name,
          amount: %{amount: product.price, currency: "USD"},
          tax_code: @tax_code,
          quantity: quantity(params["quantity"])
        }
      ],
      success_url: url(~p"/") <> "?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: url(~p"/?canceled=1"),
      reference: "#{product.id}-#{Ecto.UUID.generate()}",
      customer: blank_nil(params["email"]) && %{email: params["email"]},
      merchant_of_record: on_off(params["merchant_of_record"]),
      metadata: metadata(params["meta_key"], params["meta_value"])
    }
  end

  # The buyer comes back from Stripe with the session id: read it, and when it made a payment, keep
  # the payment at once rather than waiting for the webhook.
  defp back_from_checkout(socket, session_id) do
    case MishkaPay.fetch_checkout("stripe", session_id, @tenant) do
      {:ok, %{payment_id: payment_id} = checkout} when is_binary(payment_id) ->
        socket = assign(socket, checkout_read: checkout)

        case sync(payment_id) do
          {:ok, payment} ->
            socket
            |> select(payment.id)
            |> flash(:info, "Thank you! Your payment is below, with its details.")

          {:error, error} ->
            flash(socket, :error, MishkaPay.Ash.message(error))
        end

      {:ok, checkout} ->
        socket
        |> assign(checkout_read: checkout)
        |> flash(:info, "Thank you! The payment shows once Stripe confirms it.")

      {:error, error} ->
        flash(socket, :error, MishkaPay.Ash.message(error))
    end
  end

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
    |> assign_async(:live, fn ->
      case MishkaPay.fetch_payment(payment.provider, payment.provider_id, payment.tenant) do
        {:ok, live} -> {:ok, %{live: live}}
        {:error, error} -> {:error, MishkaPay.Ash.message(error)}
      end
    end)
  end

  defp sync(payment_id) do
    Ash.create(Payment, %{provider: "stripe", payment_id: payment_id, tenant: @tenant},
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

    assign(socket, providers: MishkaPay.Provider.all(), keys: keys, setting: setting())
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

  defp newest(nil, record), do: record

  defp newest(last, record) do
    case last.id == record.id or DateTime.compare(record.inserted_at, last.inserted_at) == :gt do
      true -> record
      false -> last
    end
  end

  defp quantity(value) do
    case Integer.parse(value || "") do
      {count, ""} when count > 0 -> count
      _one -> 1
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

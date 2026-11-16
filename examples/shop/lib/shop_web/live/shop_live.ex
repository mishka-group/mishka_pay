defmodule ShopWeb.ShopLive do
  @moduledoc """
  The demo shop's one page, on the Stripe sandbox: buy a product, see every payment the shop knows
  (newest first, live), refund one, pull an older sandbox payment in by its id, and change the
  site's payment settings, which Mishka Pay reads on its next call.
  """

  use ShopWeb, :live_view

  require Ash.Query

  alias Shop.Pay.{LiveFeed, Payment, Setting}

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
    if connected?(socket), do: Phoenix.PubSub.subscribe(Shop.PubSub, LiveFeed.topic())

    payments = list_payments()

    {:ok,
     socket
     |> assign(
       page_title: "Mishka Pay demo shop",
       products: @products,
       tenant: @tenant,
       keys?: keys?(),
       setting: setting()
     )
     |> assign(last: List.first(payments))
     |> stream(:payments, payments)}
  end

  @impl true
  def handle_params(%{"session_id" => session_id}, _uri, socket) do
    case connected?(socket) and back_from_checkout(session_id) do
      false -> {:noreply, socket}
      {:ok, message} -> {:noreply, socket |> flash(:info, message) |> push_patch(to: ~p"/")}
      {:error, message} -> {:noreply, socket |> flash(:error, message) |> push_patch(to: ~p"/")}
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
  def handle_event("buy", %{"id" => id}, socket) do
    product = Enum.find(@products, &(&1.id == id))

    checkout = %{
      provider: "stripe",
      tenant: @tenant,
      items: [
        %{
          name: product.name,
          amount: %{amount: product.price, currency: "USD"},
          tax_code: @tax_code
        }
      ],
      success_url: url(~p"/") <> "?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: url(~p"/?canceled=1"),
      reference: "#{product.id}-#{Ecto.UUID.generate()}"
    }

    Payment
    |> Ash.ActionInput.for_action(:start_checkout, %{checkout: checkout})
    |> Ash.run_action(authorize?: false)
    |> case do
      {:ok, %{url: url}} -> {:noreply, redirect(socket, external: url)}
      {:error, error} -> {:noreply, flash(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("refund", %{"payment" => id} = params, socket) do
    with {:ok, payment} <- Ash.get(Payment, id, authorize?: false),
         {:ok, refunded} <-
           payment
           |> Ash.Changeset.for_update(:refund, refund_args(payment, params))
           |> Ash.update(authorize?: false) do
      {:noreply,
       socket
       |> stream_insert(:payments, refunded)
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
         |> flash(:info, "Payment read from Stripe.")}

      {:error, error} ->
        {:noreply, flash(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("save_settings", params, socket) do
    attrs = %{
      tenant: @tenant,
      refunds: params["refunds"],
      merchant_of_record: merchant_of_record(params["merchant_of_record"])
    }

    case Ash.create(Setting, attrs, action: :save, authorize?: false) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(setting: setting)
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div :if={!@keys?} role="alert" class="alert alert-warning">
        <.icon name="hero-key" class="size-5" />
        <span>
          Set <code>STRIPE_SECRET_KEY</code> to your sandbox key (<code>sk_test_...</code>) and
          start the server again.
        </span>
      </div>

      <section>
        <h2 class="text-lg font-semibold mb-3">Buy something</h2>
        <div class="grid gap-4 sm:grid-cols-3">
          <div :for={product <- @products} class="card bg-base-200">
            <div class="card-body">
              <.icon name={product.icon} class="size-8 text-primary" />
              <h3 class="card-title">{product.name}</h3>
              <p class="text-2xl font-semibold">${product.price}</p>
              <button
                class="btn btn-primary"
                phx-click="buy"
                phx-value-id={product.id}
                phx-disable-with="Opening Stripe..."
              >
                Buy with Stripe
              </button>
            </div>
          </div>
        </div>
        <p class="text-sm opacity-70 mt-2">
          Pay with the test card <code>4242 4242 4242 4242</code>, any future date and any CVC.
        </p>
      </section>

      <section :if={@last} class="card bg-base-200 border border-success/40">
        <div class="card-body flex-row items-center gap-4">
          <.icon name="hero-shopping-bag" class="size-8 text-success" />
          <div class="flex-1">
            <p class="text-sm opacity-70">Last bought</p>
            <p class="text-lg font-semibold">
              {product_name(@last.reference)} · {money(@last.amount, @last.currency)}
            </p>
          </div>
          <span class={["badge", status_class(@last.status)]}>{@last.status}</span>
        </div>
      </section>

      <section>
        <div class="flex flex-wrap items-end justify-between gap-3 mb-3">
          <h2 class="text-lg font-semibold">Payments</h2>
          <form phx-submit="sync" class="join">
            <input
              name="payment_id"
              placeholder="pi_... from the sandbox"
              class="input input-sm join-item"
              required
            />
            <button class="btn btn-sm join-item">Read from Stripe</button>
          </form>
        </div>

        <div class="overflow-x-auto rounded-box border border-base-300">
          <table class="table">
            <thead>
              <tr>
                <th>Product</th>
                <th>Amount</th>
                <th>Refunded</th>
                <th>Status</th>
                <th>Refund</th>
              </tr>
            </thead>
            <tbody id="payments" phx-update="stream">
              <tr id="payments-empty" class="only:table-row hidden">
                <td colspan="5" class="text-center opacity-70">
                  No payments yet. Buy something above.
                </td>
              </tr>
              <tr :for={{dom_id, payment} <- @streams.payments} id={dom_id}>
                <td>
                  <div class="font-medium">{product_name(payment.reference)}</div>
                  <div class="text-xs opacity-60 font-mono">{payment.provider_id}</div>
                </td>
                <td>{money(payment.amount, payment.currency)}</td>
                <td>{money(payment.amount_refunded, payment.currency)}</td>
                <td><span class={["badge", status_class(payment.status)]}>{payment.status}</span></td>
                <td>
                  <form
                    :if={payment.status in [:paid, :partially_refunded]}
                    phx-submit="refund"
                    class="join"
                  >
                    <input type="hidden" name="payment" value={payment.id} />
                    <input
                      name="amount"
                      type="number"
                      step="0.01"
                      min="0.01"
                      placeholder="all"
                      class="input input-sm join-item w-24"
                    />
                    <button class="btn btn-sm btn-warning join-item" phx-disable-with="...">
                      Refund
                    </button>
                  </form>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="card bg-base-200">
        <form phx-submit="save_settings" class="card-body gap-4">
          <div>
            <h2 class="card-title">Site settings</h2>
            <p class="text-sm opacity-70">
              Kept in the database for the site <code>{@tenant}</code> and read by Mishka Pay on
              every call. In a multi-site project each site has its own.
            </p>
          </div>

          <fieldset class="fieldset">
            <legend class="fieldset-legend">Refunds</legend>
            <label class="label">
              <input
                type="radio"
                name="refunds"
                value="once"
                class="radio radio-sm"
                checked={@setting.refunds == :once}
              /> Once per payment: buying again is a new payment
            </label>
            <label class="label">
              <input
                type="radio"
                name="refunds"
                value="many"
                class="radio radio-sm"
                checked={@setting.refunds == :many}
              /> Many part refunds, until the payment is used up
            </label>
          </fieldset>

          <fieldset class="fieldset">
            <legend class="fieldset-legend">Stripe sells as merchant of record</legend>
            <select name="merchant_of_record" class="select select-sm w-60">
              <option value="" selected={is_nil(@setting.merchant_of_record)}>
                The Stripe account's default
              </option>
              <option value="on" selected={@setting.merchant_of_record == true}>On</option>
              <option value="off" selected={@setting.merchant_of_record == false}>Off</option>
            </select>
          </fieldset>

          <div><button class="btn btn-sm">Save settings</button></div>
        </form>
      </section>
    </Layouts.app>
    """
  end

  # One message at a time: a new answer replaces the last one, whatever its kind.
  defp flash(socket, kind, message), do: socket |> clear_flash() |> put_flash(kind, message)

  # The buyer comes back from Stripe with the session id: read it, and when it made a payment, keep
  # the payment at once rather than waiting for the webhook.
  defp back_from_checkout(session_id) do
    with {:ok, %{payment_id: payment_id}} when is_binary(payment_id) <-
           MishkaPay.fetch_checkout("stripe", session_id, @tenant),
         {:ok, _payment} <- sync(payment_id) do
      {:ok, "Thank you! Your payment is in the list below."}
    else
      {:ok, _no_payment_yet} ->
        {:ok, "Thank you! Your payment shows here once Stripe confirms it."}

      {:error, error} ->
        {:error, MishkaPay.Ash.message(error)}
    end
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
    reference = %{reference: "refund-" <> Ecto.UUID.generate()}

    case String.trim(params["amount"] || "") do
      "" -> reference
      amount -> Map.put(reference, :amount, %{amount: amount, currency: payment.currency})
    end
  end

  defp list_payments do
    Payment
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(50)
    |> Ash.read!(authorize?: false)
  end

  defp setting do
    Setting
    |> Ash.Query.filter(tenant == ^@tenant)
    |> Ash.read_one!(authorize?: false)
    |> Kernel.||(%Setting{tenant: @tenant, refunds: :once})
  end

  defp keys?, do: is_binary(System.get_env("STRIPE_SECRET_KEY"))

  defp newest(nil, record), do: record

  defp newest(last, record) do
    case last.id == record.id or DateTime.compare(record.inserted_at, last.inserted_at) == :gt do
      true -> record
      false -> last
    end
  end

  defp merchant_of_record("on"), do: true
  defp merchant_of_record("off"), do: false
  defp merchant_of_record(_account_default), do: nil

  defp product_name(reference) when is_binary(reference) do
    [id | _] = String.split(reference, "-", parts: 2)

    case Enum.find(@products, &(&1.id == id)) do
      %{name: name} -> name
      nil -> "Sandbox payment"
    end
  end

  defp product_name(_reference), do: "Sandbox payment"

  defp money(amount, currency), do: currency |> Money.new(amount) |> Money.to_string!()

  defp status_class(:paid), do: "badge-success"
  defp status_class(:refunded), do: "badge-neutral"
  defp status_class(:partially_refunded), do: "badge-info"
  defp status_class(status) when status in [:failed, :canceled], do: "badge-error"
  defp status_class(_waiting), do: "badge-warning"
end

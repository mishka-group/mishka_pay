defmodule ShopWeb.CurrenciesComponent do
  @moduledoc """
  Currencies Stripe counts in its own way: ISK, UGX, MGA and HUF. One form makes a price in one of
  them (`MishkaPay.create_price/1`, on a product of the shop's choice or a new one from
  `MishkaPay.create_product/1`), reads it back (`MishkaPay.fetch_price/3`), and shows the amount
  given, the amount Stripe answered and the amount read back side by side, so a wrong
  conversion would show at once.
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @currencies [
    {"ISK", "1500", "Icelandic krona: whole kronur, sent to Stripe with two places"},
    {"UGX", "5000", "Ugandan shilling: whole shillings, sent to Stripe with two places"},
    {"MGA", "10000", "Malagasy ariary: whole ariary, no places at Stripe"},
    {"HUF", "1990", "Hungarian forint: two places"}
  ]

  @impl true
  def mount(socket), do: {:ok, assign(socket, made: nil, error: nil)}

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, tenant: assigns.tenant)}

  @impl true
  def handle_event("make", params, socket) do
    tenant = socket.assigns.tenant
    amount = %{amount: String.trim(params["amount"] || ""), currency: params["currency"]}

    with {:ok, product_id} <- product(String.trim(params["product_id"] || ""), tenant),
         {:ok, price} <-
           MishkaPay.create_price(%{
             provider: "stripe",
             tenant: tenant,
             product_id: product_id,
             amount: amount
           }),
         {:ok, read} <- MishkaPay.fetch_price("stripe", price.id, tenant) do
      {:noreply, assign(socket, made: %{given: amount, price: price, read: read}, error: nil)}
    else
      {:error, error} ->
        {:noreply, assign(socket, made: nil, error: MishkaPay.Ash.message(error))}
    end
  end

  defp product("", tenant) do
    attrs = %{provider: "stripe", tenant: tenant, name: "Currency demo"}

    with {:ok, product} <- MishkaPay.create_product(attrs), do: {:ok, product.id}
  end

  defp product(product_id, _tenant), do: {:ok, product_id}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, currencies: @currencies)

    ~H"""
    <section data-testid="currencies" class="space-y-4">
      <.section_title icon="hero-currency-dollar" title="Prices in ISK, UGX, MGA and HUF" />
      <p class="text-sm opacity-70">
        Stripe counts these currencies in its own way. Make a price in one and read it back: the
        three amounts below must match.
      </p>
      <.hint>MishkaPay.create_price/1, MishkaPay.fetch_price/3</.hint>

      <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="currencies-error">
        {@error}
      </div>

      <form
        id="currencies-form"
        phx-submit="make"
        phx-target={@myself}
        class="card bg-base-200"
        data-testid="currencies-form"
      >
        <div class="card-body gap-3">
          <div class="grid gap-3 sm:grid-cols-3">
            <label class="fieldset">
              <span class="fieldset-legend">Currency</span>
              <select name="currency" class="select select-sm" data-testid="currencies-currency">
                <option :for={{code, _amount, note} <- @currencies} value={code}>
                  {code}: {note}
                </option>
              </select>
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Amount</span>
              <input
                name="amount"
                value="1500"
                class="input input-sm"
                data-testid="currencies-amount"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Product id (empty: a new one)</span>
              <input
                name="product_id"
                placeholder="prod_..."
                class="input input-sm"
                data-testid="currencies-product"
              />
            </label>
          </div>
          <div>
            <button
              class="btn btn-sm btn-primary"
              phx-disable-with="Asking Stripe..."
              data-testid="currencies-submit"
            >
              Make the price and read it back
            </button>
          </div>
        </div>
      </form>

      <div
        :if={@made}
        class="card bg-base-200 border border-primary/40"
        data-testid="currencies-result"
      >
        <div class="card-body">
          <dl class="grid grid-cols-2 gap-y-1 text-sm max-w-xl">
            <dt class="opacity-70">Price</dt>
            <dd class="font-mono text-xs" data-testid="currencies-price-id">{@made.price.id}</dd>
            <dt class="opacity-70">Given</dt>
            <dd data-testid="currencies-given">{@made.given.amount} {@made.given.currency}</dd>
            <dt class="opacity-70">Stripe answered</dt>
            <dd data-testid="currencies-made">{money(@made.price.amount)}</dd>
            <dt class="opacity-70">Read back</dt>
            <dd data-testid="currencies-read">{money(@made.read.amount)}</dd>
            <dt class="opacity-70">Same</dt>
            <dd data-testid="currencies-same">{if same?(@made), do: "yes", else: "no"}</dd>
          </dl>
        </div>
      </div>
    </section>
    """
  end

  defp same?(%{given: given, price: %{amount: %Money{} = made}, read: %{amount: %Money{} = read}}) do
    Money.equal?(made, read) and
      Decimal.equal?(made.amount, Decimal.new(given.amount)) and
      to_string(made.currency) == given.currency
  end

  defp same?(_made), do: false

  # The exact amount kept, not a formatted one: money formatting rounds HUF to whole forints, as
  # cash is paid, and this part shows that nothing is lost.
  defp money(%Money{amount: amount, currency: currency}),
    do: "#{currency} #{Decimal.to_string(amount, :normal)}"

  defp money(_none), do: "–"
end

defmodule ShopWeb.DiscountsComponent do
  @moduledoc """
  The discounts part of the demo shop, read live from Stripe: make a coupon
  (`MishkaPay.create_coupon/1`: a percent or an amount off, once, for some months or forever, with
  its limits), list them (`MishkaPay.list_coupons/3`) and remove one
  (`MishkaPay.delete_coupon/3`); give a coupon promotion codes buyers type
  (`MishkaPay.create_promotion_code/1`, with their own limits), list them
  (`MishkaPay.list_promotion_codes/3`) and turn one off or on again
  (`MishkaPay.update_promotion_code/1`). Codes are used in "Checkout options".
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, coupons: [], codes: %{}, open: nil, loaded?: false, new?: false)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, tenant: assigns.tenant)

    case socket.assigns.loaded? do
      true -> {:ok, socket}
      false -> {:ok, socket |> assign(loaded?: true) |> load()}
    end
  end

  @impl true
  def handle_event("toggle_new", _params, socket),
    do: {:noreply, assign(socket, new?: !socket.assigns.new?)}

  def handle_event("create_coupon", params, socket) do
    case MishkaPay.create_coupon(coupon_attrs(params, socket.assigns.tenant)) do
      {:ok, coupon} ->
        {:noreply,
         socket
         |> assign(new?: false, open: coupon.id)
         |> load()
         |> say(:info, "Coupon #{coupon.name || coupon.id} made on Stripe.")}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("open", %{"id" => id}, socket) do
    case socket.assigns.open do
      ^id -> {:noreply, assign(socket, open: nil)}
      _other -> {:noreply, socket |> assign(open: id) |> load_codes(id)}
    end
  end

  def handle_event("delete_coupon", %{"id" => id}, socket) do
    case MishkaPay.delete_coupon("stripe", id, socket.assigns.tenant) do
      :ok ->
        {:noreply,
         socket
         |> assign(open: nil)
         |> load()
         |> say(:info, "Coupon removed. What it already took off stays taken off.")}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event("create_code", %{"coupon_id" => coupon_id} = params, socket) do
    case MishkaPay.create_promotion_code(code_attrs(params, socket.assigns.tenant)) do
      {:ok, code} ->
        {:noreply,
         socket
         |> load_codes(coupon_id)
         |> say(:info, "Code #{code.code} made. Buyers can type it now.")}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  def handle_event(
        "toggle_code",
        %{"id" => id, "coupon_id" => coupon_id, "active" => active},
        socket
      ) do
    attrs = %{provider: "stripe", tenant: socket.assigns.tenant, id: id, active: active == "true"}

    case MishkaPay.update_promotion_code(attrs) do
      {:ok, code} ->
        {:noreply,
         socket
         |> load_codes(coupon_id)
         |> say(:info, "Code #{code.code} is #{if code.active, do: "on", else: "off"} now.")}

      {:error, error} ->
        {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="discounts" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <.section_title icon="hero-ticket" title="Coupons and promotion codes" />
        <button
          class="btn btn-sm btn-primary"
          phx-click="toggle_new"
          phx-target={@myself}
          data-testid="new-coupon-toggle"
        >
          <.icon name="hero-plus" class="size-4" /> New coupon
        </button>
      </div>
      <.hint>MishkaPay.list_coupons/3, read live from Stripe</.hint>

      <.new_coupon :if={@new?} myself={@myself} />

      <div class="overflow-x-auto rounded-box border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>Coupon</th>
              <th>Takes off</th>
              <th>For</th>
              <th>Used</th>
              <th>State</th>
            </tr>
          </thead>
          <tbody data-testid="coupon-rows">
            <tr :if={@coupons == []}>
              <td colspan="5" class="text-center opacity-70" data-testid="coupons-empty">
                No coupons yet. Make one to give buyers a discount.
              </td>
            </tr>
            <tr
              :for={coupon <- @coupons}
              class="hover:bg-base-200 cursor-pointer"
              phx-click="open"
              phx-value-id={coupon.id}
              phx-target={@myself}
              data-testid="coupon-row"
              data-coupon-id={coupon.id}
            >
              <td>
                <div class="font-medium">{coupon.name || "–"}</div>
                <div class="text-xs opacity-60 font-mono">{coupon.id}</div>
              </td>
              <td data-testid="coupon-off">{off(coupon)}</td>
              <td class="text-sm">{how_long(coupon)}</td>
              <td class="text-sm">{used(coupon)}</td>
              <td>
                <span class={["badge badge-sm", (coupon.valid && "badge-success") || "badge-ghost"]}>
                  {if coupon.valid, do: "can be used", else: "used up"}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.coupon_card
        :for={coupon <- @coupons}
        :if={@open == coupon.id}
        coupon={coupon}
        codes={Map.get(@codes, coupon.id, [])}
        myself={@myself}
      />
    </section>
    """
  end

  attr :myself, :any, required: true

  defp new_coupon(assigns) do
    ~H"""
    <form
      phx-submit="create_coupon"
      phx-target={@myself}
      class="card bg-base-200"
      data-testid="new-coupon-form"
    >
      <div class="card-body gap-3">
        <h3 class="font-medium">New coupon</h3>
        <.hint>MishkaPay.create_coupon/1</.hint>
        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <label class="fieldset">
            <span class="fieldset-legend">Name the buyer sees</span>
            <input
              name="name"
              placeholder="Spring sale"
              class="input input-sm"
              data-testid="coupon-name"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Own id (optional)</span>
            <input
              name="coupon_id"
              placeholder="SPRING"
              class="input input-sm"
              data-testid="coupon-id"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Percent off</span>
            <input
              name="percent_off"
              type="number"
              min="0.01"
              max="100"
              step="0.01"
              placeholder="20"
              class="input input-sm"
              data-testid="coupon-percent"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">or amount off, USD</span>
            <input
              name="amount_off"
              type="number"
              min="0.01"
              step="0.01"
              placeholder="5.00"
              class="input input-sm"
              data-testid="coupon-amount"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">For</span>
            <select name="duration" class="select select-sm" data-testid="coupon-duration">
              <option value="once">One payment</option>
              <option value="repeating">Some months of a plan</option>
              <option value="forever">Every payment, forever</option>
            </select>
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Months (with "some months")</span>
            <input
              name="duration_in_months"
              type="number"
              min="1"
              class="input input-sm"
              data-testid="coupon-months"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Used at most, in all</span>
            <input
              name="max_redemptions"
              type="number"
              min="1"
              class="input input-sm"
              data-testid="coupon-max"
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend">Last day it works</span>
            <input name="redeem_by" type="date" class="input input-sm" data-testid="coupon-redeem-by" />
          </label>
        </div>
        <p class="text-xs opacity-70">Give a percent or an amount, one of them.</p>
        <div>
          <button
            class="btn btn-sm btn-primary"
            phx-disable-with="Asking Stripe..."
            data-testid="coupon-submit"
          >
            Make coupon
          </button>
        </div>
      </div>
    </form>
    """
  end

  attr :coupon, :map, required: true
  attr :codes, :list, required: true
  attr :myself, :any, required: true

  defp coupon_card(assigns) do
    ~H"""
    <div
      class="card bg-base-200 border border-primary/40"
      data-testid="coupon-details"
      data-coupon-id={@coupon.id}
    >
      <div class="card-body gap-4">
        <div class="flex flex-wrap items-center gap-3">
          <h3 class="card-title flex-1 min-w-0 flex-wrap">
            {@coupon.name || @coupon.id} · {off(@coupon)}
            <code class="text-sm opacity-70">{@coupon.id}</code>
          </h3>
          <a
            href={"https://dashboard.stripe.com/test/coupons/#{@coupon.id}"}
            target="_blank"
            class="btn btn-ghost btn-sm"
            data-testid="coupon-stripe-link"
          >
            Stripe <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </a>
          <button
            class="btn btn-error btn-outline btn-sm"
            phx-click="delete_coupon"
            phx-value-id={@coupon.id}
            phx-target={@myself}
            data-confirm="Remove this coupon? Its codes stop working; discounts already given stay."
            data-testid="coupon-delete"
          >
            Remove coupon
          </button>
        </div>

        <div class="rounded-box bg-base-100 p-4" data-testid="promotion-codes">
          <h4 class="font-medium">Promotion codes ({length(@codes)})</h4>
          <.hint>MishkaPay.list_promotion_codes/3 and MishkaPay.update_promotion_code/1</.hint>
          <p :if={@codes == []} class="text-sm opacity-70" data-testid="codes-empty">
            No codes yet. A code is what the buyer types on Stripe's page.
          </p>
          <ul class="space-y-1 mt-2">
            <li
              :for={code <- @codes}
              class="flex flex-wrap items-center gap-2 text-sm"
              data-testid="promotion-code"
              data-code={code.code}
              data-active={to_string(code.active)}
            >
              <code class="font-bold">{code.code}</code>
              <code class="text-xs opacity-60">{code.id}</code>
              <span class={["badge badge-sm", (code.active && "badge-success") || "badge-ghost"]}>
                {if code.active, do: "on", else: "off"}
              </span>
              <span class="opacity-70">{code_limits(code)}</span>
              <button
                class="btn btn-xs"
                phx-click="toggle_code"
                phx-value-id={code.id}
                phx-value-coupon_id={@coupon.id}
                phx-value-active={to_string(!code.active)}
                phx-target={@myself}
                data-testid="code-toggle"
              >
                {if code.active, do: "Turn off", else: "Turn on"}
              </button>
            </li>
          </ul>
        </div>

        <form
          phx-submit="create_code"
          phx-target={@myself}
          class="rounded-box bg-base-100 p-4"
          data-testid="new-code-form"
        >
          <h4 class="font-medium">New promotion code</h4>
          <.hint>MishkaPay.create_promotion_code/1</.hint>
          <input type="hidden" name="coupon_id" value={@coupon.id} />
          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5 items-end">
            <label class="fieldset">
              <span class="fieldset-legend">Code</span>
              <input
                name="code"
                placeholder="SPRING20 (empty: Stripe makes one)"
                class="input input-sm"
                data-testid="code-code"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Used at most</span>
              <input
                name="max_redemptions"
                type="number"
                min="1"
                class="input input-sm"
                data-testid="code-max"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Order at least, USD</span>
              <input
                name="minimum_amount"
                type="number"
                min="0.01"
                step="0.01"
                class="input input-sm"
                data-testid="code-minimum"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Last day</span>
              <input name="expires_at" type="date" class="input input-sm" data-testid="code-expires" />
            </label>
            <label class="label gap-2 text-sm">
              <input
                type="checkbox"
                name="first_time_transaction"
                value="true"
                class="checkbox checkbox-sm"
                data-testid="code-first-time"
              /> First purchase only
            </label>
          </div>
          <button
            class="btn btn-sm mt-3"
            phx-disable-with="Asking Stripe..."
            data-testid="code-submit"
          >
            Make code
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp load(socket) do
    case MishkaPay.list_coupons("stripe", socket.assigns.tenant, limit: 20) do
      {:ok, coupons} ->
        socket = assign(socket, coupons: coupons)

        case socket.assigns.open do
          nil -> socket
          id -> load_codes(socket, id)
        end

      {:error, error} ->
        say(socket, :error, MishkaPay.Ash.message(error))
    end
  end

  defp load_codes(socket, coupon_id) do
    case MishkaPay.list_promotion_codes("stripe", socket.assigns.tenant,
           coupon_id: coupon_id,
           limit: 20
         ) do
      {:ok, codes} -> assign(socket, codes: Map.put(socket.assigns.codes, coupon_id, codes))
      {:error, error} -> say(socket, :error, MishkaPay.Ash.message(error))
    end
  end

  # Only what was typed: a blank field is left out, and Mishka Pay checks the rest.
  defp coupon_attrs(params, tenant) do
    %{
      provider: "stripe",
      tenant: tenant,
      id: present(params["coupon_id"]),
      name: present(params["name"]),
      percent_off: present(params["percent_off"]),
      amount_off: usd(params["amount_off"]),
      duration: params["duration"],
      duration_in_months: integer(params["duration_in_months"]),
      max_redemptions: integer(params["max_redemptions"]),
      redeem_by: end_of_day(params["redeem_by"])
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp code_attrs(params, tenant) do
    %{
      provider: "stripe",
      tenant: tenant,
      coupon_id: params["coupon_id"],
      code: present(params["code"]),
      max_redemptions: integer(params["max_redemptions"]),
      minimum_amount: usd(params["minimum_amount"]),
      expires_at: end_of_day(params["expires_at"]),
      first_time_transaction: params["first_time_transaction"] == "true" || nil
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp present(value) do
    case String.trim(value || "") do
      "" -> nil
      text -> text
    end
  end

  defp usd(value), do: present(value) && %{amount: present(value), currency: "USD"}

  defp integer(value) do
    case Integer.parse(present(value) || "") do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp end_of_day(value) do
    with text when is_binary(text) <- present(value),
         {:ok, date} <- Date.from_iso8601(text),
         {:ok, at} <- DateTime.new(date, ~T[23:59:59], "Etc/UTC") do
      at
    else
      _no_date -> nil
    end
  end

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end

  defp off(%{percent_off: %Decimal{} = percent}), do: "#{Decimal.normalize(percent)}% off"
  defp off(%{amount_off: %Money{} = amount}), do: "#{Money.to_string!(amount)} off"
  defp off(_coupon), do: "–"

  defp how_long(%{duration: :repeating, duration_in_months: months}), do: "#{months} months"
  defp how_long(%{duration: :forever}), do: "every payment"
  defp how_long(_once), do: "one payment"

  defp used(%{times_redeemed: times, max_redemptions: nil}), do: "#{times || 0} times"
  defp used(%{times_redeemed: times, max_redemptions: max}), do: "#{times || 0} of #{max}"

  defp code_limits(code) do
    [
      code.max_redemptions && "used #{code.times_redeemed || 0} of #{code.max_redemptions}",
      code.minimum_amount && "order at least #{Money.to_string!(code.minimum_amount)}",
      code.first_time_transaction && "first purchase only",
      code.expires_at && "until #{Calendar.strftime(code.expires_at, "%Y-%m-%d")}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end
end

defmodule ShopWeb.TaxSetupComponent do
  @moduledoc """
  The site's tax setup on Stripe, in the demo shop: tax rates set by hand
  (`MishkaPay.create_tax_rate/1`, `list_tax_rates/3`, archived with `update_tax_rate/1`), where
  the site is registered to collect tax (`MishkaPay.create_tax_registration/1`,
  `list_tax_registrations/3`, ended with `expire_tax_registration/4`; the form offers only the
  kinds Stripe takes in the country typed, a state where the kind needs one, and the place of
  supply schemes `MishkaPay.Providers.Stripe.place_of_supply_schemes/2` gives for a standard
  registration), and Stripe Tax's settings
  (`MishkaPay.fetch_tax_settings/2`, `update_tax_settings/1`): the head office and the defaults.

  Nothing is read when the page opens: "Show tax setup" reads the three in the background
  (`start_async`), and "Read again" reads them once more.
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @rate_form %{
    "display_name" => "VAT",
    "percentage" => "19",
    "inclusive" => "true",
    "country" => "DE",
    "tax_type" => "vat"
  }

  @settings_fields ~w(country postal_code state city line1 tax_code tax_behavior)

  @registration_form %{
    "country" => "DE",
    "type" => "standard",
    "state" => "",
    "place_of_supply_scheme" => "standard",
    "starts_on" => ""
  }

  # The registration kinds Stripe takes in each country (its API's `country_options`).
  @eu ~w(AT BE BG CY CZ DE DK EE ES FI FR GR HR HU IE IT LT LU LV MT NL PL PT RO SE SI SK)
  @simplified_only ~w(AM AZ BJ BW BY CI CL CM CO CR CV EC EG GE GH ID IN KE KG KH KR KZ LA LK MA
                      MD MU MX MY NG NP PE PH RU SA SN TH TJ TR TW TZ UA UG UZ VN ZM)
  @us_kinds ~w(state_sales_tax state_communications_tax state_retail_delivery_fee
               local_amusement_tax local_lease_tax)

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open?: false,
       reading?: false,
       rates: [],
       registrations: [],
       settings: nil,
       settings_form: nil,
       rate_form: @rate_form,
       registration_form: @registration_form,
       notice: nil,
       error: nil
     )}
  end

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, tenant: assigns.tenant)}

  @impl true
  def handle_event("show", _params, socket),
    do: {:noreply, socket |> assign(open?: true) |> read()}

  def handle_event("read", _params, socket), do: {:noreply, read(socket)}

  # Each form keeps what is typed or picked: the registration form re-renders the part on every
  # change, and that must not reset the other two.
  def handle_event("draft_rate", params, socket),
    do: {:noreply, assign(socket, rate_form: Map.take(params, Map.keys(@rate_form)))}

  def handle_event("draft_settings", params, socket),
    do: {:noreply, assign(socket, settings_form: Map.take(params, @settings_fields))}

  def handle_event("create_rate", params, socket) do
    form = Map.take(params, Map.keys(@rate_form))

    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      display_name: form["display_name"],
      percentage: form["percentage"],
      inclusive: form["inclusive"] == "true",
      country: blank(form["country"]),
      tax_type: blank(form["tax_type"])
    }

    case MishkaPay.create_tax_rate(attrs) do
      {:ok, rate} ->
        {:noreply,
         socket
         |> update(:rates, &[rate | &1])
         |> assign(rate_form: form)
         |> done("Tax rate #{rate.id} made: put its id on a line's tax_rate_ids.")}

      {:error, error} ->
        {:noreply, socket |> assign(rate_form: form) |> failed(error)}
    end
  end

  def handle_event("archive_rate", %{"id" => id}, socket) do
    attrs = %{provider: "stripe", tenant: socket.assigns.tenant, id: id, active: false}

    case MishkaPay.update_tax_rate(attrs) do
      {:ok, rate} ->
        {:noreply,
         socket
         |> update(:rates, fn rates -> Enum.map(rates, &((&1.id == rate.id && rate) || &1)) end)
         |> done("Tax rate #{rate.id} archived: lines that have it keep it.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  def handle_event("draft_registration", params, socket),
    do: {:noreply, assign(socket, registration_form: registration_form(params))}

  def handle_event("create_registration", params, socket) do
    form = registration_form(params)

    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      country: form["country"],
      type: form["type"],
      state: if(state?(form), do: blank(form["state"])),
      place_of_supply_scheme: if(scheme?(form), do: form["place_of_supply_scheme"]),
      active_from: starts(form["starts_on"])
    }

    case MishkaPay.create_tax_registration(attrs) do
      {:ok, registration} ->
        {:noreply,
         socket
         |> update(:registrations, &[registration | &1])
         |> assign(registration_form: form)
         |> done("Registered in #{registration.country}: Stripe Tax charges tax there now.")}

      {:error, error} ->
        {:noreply, socket |> assign(registration_form: form) |> failed(error)}
    end
  end

  def handle_event("end_registration", %{"id" => id}, socket) do
    case MishkaPay.expire_tax_registration("stripe", id, socket.assigns.tenant) do
      {:ok, registration} ->
        {:noreply,
         socket
         |> update(:registrations, fn registrations ->
           Enum.map(registrations, &((&1.id == registration.id && registration) || &1))
         end)
         |> done("Registration #{registration.id} ended.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  def handle_event("update_settings", params, socket) do
    socket = assign(socket, settings_form: Map.take(params, @settings_fields))

    office =
      params
      |> Map.take(~w(country postal_code state city line1))
      |> Map.reject(fn {_field, value} -> blank(value) == nil end)

    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      head_office: (office != %{} && office) || nil,
      tax_code: blank(params["tax_code"]),
      tax_behavior: blank(params["tax_behavior"])
    }

    case MishkaPay.update_tax_settings(attrs) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(settings: settings, settings_form: nil)
         |> done("Tax settings saved.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  @impl true
  def handle_async(:tax_setup, {:ok, {:ok, rates, registrations, settings}}, socket) do
    {:noreply,
     assign(socket,
       reading?: false,
       rates: rates,
       registrations: registrations,
       settings: settings,
       settings_form: nil
     )}
  end

  def handle_async(:tax_setup, {:ok, {:error, error}}, socket),
    do: {:noreply, socket |> assign(reading?: false) |> failed(error)}

  def handle_async(:tax_setup, {:exit, reason}, socket),
    do: {:noreply, assign(socket, reading?: false, error: inspect(reason), notice: nil)}

  defp read(socket) do
    tenant = socket.assigns.tenant

    socket
    |> assign(reading?: true, error: nil)
    |> start_async(:tax_setup, fn ->
      with {:ok, %MishkaPay.Page{items: rates}} <-
             MishkaPay.list_tax_rates("stripe", tenant, limit: 20),
           {:ok, %MishkaPay.Page{items: registrations}} <-
             MishkaPay.list_tax_registrations("stripe", tenant, status: :all, limit: 20),
           {:ok, settings} <- MishkaPay.fetch_tax_settings("stripe", tenant) do
        {:ok, rates, registrations, settings}
      end
    end)
  end

  # The form as typed, with a kind the country takes and a scheme the kind takes: the first one
  # when the country or the kind changed.
  # A date picked in the form is its midnight; Mishka Pay sends today's as Stripe's `now`.
  defp starts(date) do
    case Date.from_iso8601(to_string(date)) do
      {:ok, day} -> DateTime.new!(day, ~T[00:00:00], "Etc/UTC")
      {:error, _empty} -> nil
    end
  end

  defp registration_form(params) do
    form = Map.merge(@registration_form, Map.take(params, Map.keys(@registration_form)))
    country = form["country"] |> to_string() |> String.trim() |> String.upcase()
    kinds = kinds(country)
    type = (form["type"] in kinds && form["type"]) || hd(kinds)
    form = %{form | "country" => country, "type" => type}
    schemes = Enum.map(schemes(form), &Atom.to_string/1)
    scheme = form["place_of_supply_scheme"]
    %{form | "place_of_supply_scheme" => (scheme in schemes && scheme) || List.first(schemes)}
  end

  defp kinds(country) when country in @eu, do: ~w(standard oss_union oss_non_union ioss)
  defp kinds("US"), do: @us_kinds
  defp kinds("CA"), do: ~w(standard province_standard simplified)
  defp kinds(country) when country in @simplified_only, do: ~w(simplified)
  defp kinds(_country), do: ~w(standard)

  defp state?(%{"country" => "US"}), do: true
  defp state?(%{"country" => "CA", "type" => "province_standard"}), do: true
  defp state?(_form), do: false

  defp schemes(%{"country" => country, "type" => type}),
    do: MishkaPay.Providers.Stripe.place_of_supply_schemes(country, type)

  defp scheme?(form), do: schemes(form) != []

  defp scheme_label(:small_seller), do: "small seller (under the EU threshold)"
  defp scheme_label(:inbound_goods), do: "inbound goods"
  defp scheme_label(:standard), do: "standard"

  defp done(socket, notice), do: assign(socket, notice: notice, error: nil)
  defp failed(socket, error), do: assign(socket, error: MishkaPay.Ash.message(error), notice: nil)

  defp blank(nil), do: nil

  defp blank(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  defp office(nil, _field), do: nil
  defp office(%MishkaPay.Address{} = address, field), do: Map.get(address, field)

  # A settings field as typed since the last read, or as Stripe holds it.
  defp setting(%{} = form, _settings, field), do: form[to_string(field)]
  defp setting(nil, settings, :tax_code), do: settings.tax_code

  defp setting(nil, settings, :tax_behavior),
    do: settings.tax_behavior && to_string(settings.tax_behavior)

  defp setting(nil, settings, field), do: office(settings.head_office, field)

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="tax-setup" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <.section_title icon="hero-receipt-percent" title="Tax setup" />
        <button
          :if={!@open?}
          class="btn btn-sm"
          phx-click="show"
          phx-target={@myself}
          data-testid="tax-setup-show"
        >
          Show tax setup
        </button>
        <button
          :if={@open?}
          class="btn btn-sm btn-ghost"
          phx-click="read"
          phx-target={@myself}
          disabled={@reading?}
          data-testid="tax-setup-read"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Read again
        </button>
      </div>
      <p class="text-sm opacity-70">
        Tax rates you set by hand, where the site is registered to collect tax, and Stripe Tax's settings.
      </p>

      <div :if={@notice} role="status" class="alert alert-success py-2" data-testid="tax-setup-notice">
        {@notice}
      </div>
      <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="tax-setup-error">
        {@error}
      </div>
      <span
        :if={@reading?}
        class="loading loading-spinner loading-sm"
        data-testid="tax-setup-reading"
      ></span>

      <div :if={@open? and !@reading?} class="space-y-6">
        <div class="space-y-2">
          <h3 class="font-semibold">Tax rates</h3>
          <.hint>
            MishkaPay.create_tax_rate/1, list_tax_rates/3, update_tax_rate/1 (active: false)
          </.hint>
          <form
            id="tax-rate-form"
            phx-change="draft_rate"
            phx-submit="create_rate"
            phx-target={@myself}
            class="flex flex-wrap items-end gap-2 rounded-box bg-base-200 p-3"
            data-testid="tax-rate-form"
          >
            <label class="fieldset">
              <span class="fieldset-legend">Name on the bill</span>
              <input
                name="display_name"
                value={@rate_form["display_name"]}
                class="input input-sm w-32"
                data-testid="tax-rate-name"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Percent</span>
              <input
                name="percentage"
                value={@rate_form["percentage"]}
                inputmode="decimal"
                class="input input-sm w-20"
                data-testid="tax-rate-percentage"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">The price</span>
              <select name="inclusive" class="select select-sm" data-testid="tax-rate-inclusive">
                <option value="true" selected={@rate_form["inclusive"] == "true"}>
                  holds the tax
                </option>
                <option value="false" selected={@rate_form["inclusive"] == "false"}>
                  gets it on top
                </option>
              </select>
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Country</span>
              <input
                name="country"
                value={@rate_form["country"]}
                maxlength="2"
                class="input input-sm w-16"
                data-testid="tax-rate-country"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Kind</span>
              <input
                name="tax_type"
                value={@rate_form["tax_type"]}
                placeholder="vat, sales_tax, gst"
                class="input input-sm w-28"
                data-testid="tax-rate-type"
              />
            </label>
            <button class="btn btn-sm btn-primary" data-testid="tax-rate-create">Make rate</button>
          </form>

          <div class="overflow-x-auto rounded-box border border-base-300">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Tax rate</th>
                  <th>Name</th>
                  <th>Percent</th>
                  <th>Price</th>
                  <th>Where</th>
                  <th>Active</th>
                  <th></th>
                </tr>
              </thead>
              <tbody data-testid="tax-rate-rows">
                <tr :if={@rates == []}>
                  <td colspan="7" class="text-center opacity-70" data-testid="tax-rates-empty">
                    No tax rates yet.
                  </td>
                </tr>
                <tr :for={rate <- @rates} data-testid="tax-rate-row" data-rate-id={rate.id}>
                  <td class="font-mono text-xs">{rate.id}</td>
                  <td>{rate.display_name}</td>
                  <td data-testid="tax-rate-percent">
                    {rate.percentage && Decimal.to_string(rate.percentage, :normal)}%
                  </td>
                  <td>{if rate.inclusive, do: "holds the tax", else: "tax on top"}</td>
                  <td>
                    {Enum.join(Enum.reject([rate.country, rate.state, rate.tax_type], &is_nil/1), " ")}
                  </td>
                  <td data-testid="tax-rate-active">{if rate.active, do: "yes", else: "no"}</td>
                  <td>
                    <button
                      :if={rate.active}
                      class="btn btn-xs btn-ghost"
                      phx-click="archive_rate"
                      phx-value-id={rate.id}
                      phx-target={@myself}
                      phx-disable-with="Archiving..."
                      data-confirm="Archive this rate? No new line takes it; lines that have it keep it."
                      data-testid="tax-rate-archive"
                    >
                      Archive
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="space-y-2">
          <h3 class="font-semibold">Registrations</h3>
          <.hint>
            MishkaPay.create_tax_registration/1, list_tax_registrations/3, expire_tax_registration/4
          </.hint>
          <form
            id="tax-registration-form"
            phx-change="draft_registration"
            phx-submit="create_registration"
            phx-target={@myself}
            class="flex flex-wrap items-end gap-2 rounded-box bg-base-200 p-3"
            data-testid="tax-registration-form"
          >
            <label class="fieldset">
              <span class="fieldset-legend">Country</span>
              <input
                name="country"
                value={@registration_form["country"]}
                maxlength="2"
                class="input input-sm w-16"
                data-testid="tax-registration-country"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Kind</span>
              <select name="type" class="select select-sm" data-testid="tax-registration-type">
                <option
                  :for={kind <- kinds(@registration_form["country"])}
                  value={kind}
                  selected={kind == @registration_form["type"]}
                >
                  {kind}
                </option>
              </select>
            </label>
            <label :if={scheme?(@registration_form)} class="fieldset">
              <span class="fieldset-legend">Place of supply scheme</span>
              <select
                name="place_of_supply_scheme"
                class="select select-sm"
                data-testid="tax-registration-scheme"
              >
                <option
                  :for={scheme <- schemes(@registration_form)}
                  value={scheme}
                  selected={Atom.to_string(scheme) == @registration_form["place_of_supply_scheme"]}
                >
                  {scheme_label(scheme)}
                </option>
              </select>
            </label>
            <label :if={state?(@registration_form)} class="fieldset">
              <span class="fieldset-legend">
                {if @registration_form["country"] == "CA", do: "Province", else: "State"}
              </span>
              <input
                name="state"
                value={@registration_form["state"]}
                maxlength="2"
                class="input input-sm w-24"
                data-testid="tax-registration-state"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Starts on (empty: now)</span>
              <input
                type="date"
                name="starts_on"
                value={@registration_form["starts_on"]}
                class="input input-sm"
                data-testid="tax-registration-starts"
              />
            </label>
            <button class="btn btn-sm btn-primary" data-testid="tax-registration-create">
              Register
            </button>
          </form>

          <div class="overflow-x-auto rounded-box border border-base-300">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Registration</th>
                  <th>Where</th>
                  <th>Kind</th>
                  <th>Status</th>
                  <th>Ends</th>
                  <th></th>
                </tr>
              </thead>
              <tbody data-testid="tax-registration-rows">
                <tr :if={@registrations == []}>
                  <td colspan="6" class="text-center opacity-70" data-testid="tax-registrations-empty">
                    No registrations: Stripe Tax charges no tax anywhere.
                  </td>
                </tr>
                <tr
                  :for={registration <- @registrations}
                  data-testid="tax-registration-row"
                  data-registration-id={registration.id}
                >
                  <td class="font-mono text-xs">{registration.id}</td>
                  <td>{registration.country} {registration.state}</td>
                  <td>{registration.type}</td>
                  <td data-testid="tax-registration-status">{registration.status}</td>
                  <td class="text-xs">
                    {registration.expires_at &&
                      Calendar.strftime(registration.expires_at, "%Y-%m-%d %H:%M")}
                  </td>
                  <td>
                    <button
                      :if={registration.status == :active and is_nil(registration.expires_at)}
                      class="btn btn-xs btn-ghost"
                      phx-click="end_registration"
                      phx-value-id={registration.id}
                      phx-target={@myself}
                      phx-disable-with="Ending..."
                      data-confirm="End this registration now? Stripe Tax stops charging tax there."
                      data-testid="tax-registration-end"
                    >
                      End now
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div :if={@settings} class="space-y-2">
          <h3 class="font-semibold">Settings</h3>
          <.hint>MishkaPay.fetch_tax_settings/2, update_tax_settings/1</.hint>
          <p class="text-sm" data-testid="tax-settings-status">
            Stripe Tax is
            <span class="font-semibold">{@settings.status}</span><span :if={
              @settings.missing_fields not in [nil, []]
            }>: it still needs {Enum.join(@settings.missing_fields, ", ")}</span>.
          </p>
          <form
            id="tax-settings-form"
            phx-change="draft_settings"
            phx-submit="update_settings"
            phx-target={@myself}
            class="flex flex-wrap items-end gap-2 rounded-box bg-base-200 p-3"
            data-testid="tax-settings-form"
          >
            <label
              :for={
                {field, label, width} <- [
                  {:country, "Head office country", "w-16"},
                  {:postal_code, "Postal code", "w-24"},
                  {:state, "State", "w-16"},
                  {:city, "City", "w-32"},
                  {:line1, "Street", "w-40"}
                ]
              }
              class="fieldset"
            >
              <span class="fieldset-legend">{label}</span>
              <input
                name={field}
                value={setting(@settings_form, @settings, field)}
                class={["input input-sm", width]}
                data-testid={"tax-settings-#{field}"}
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Default tax code</span>
              <input
                name="tax_code"
                value={setting(@settings_form, @settings, :tax_code)}
                placeholder="txcd_10000000"
                class="input input-sm w-36"
                data-testid="tax-settings-tax-code"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">A price without its own</span>
              <select name="tax_behavior" class="select select-sm" data-testid="tax-settings-behavior">
                <option
                  value=""
                  selected={setting(@settings_form, @settings, :tax_behavior) in [nil, ""]}
                >
                  not set
                </option>
                <option
                  :for={
                    {value, label} <- [
                      {:exclusive, "tax on top"},
                      {:inclusive, "holds the tax"},
                      {:inferred_by_currency, "by its currency"}
                    ]
                  }
                  value={value}
                  selected={setting(@settings_form, @settings, :tax_behavior) == to_string(value)}
                >
                  {label}
                </option>
              </select>
            </label>
            <button class="btn btn-sm btn-primary" data-testid="tax-settings-save">Save</button>
          </form>
        </div>
      </div>
    </section>
    """
  end
end

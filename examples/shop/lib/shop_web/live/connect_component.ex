defmodule ShopWeb.ConnectComponent do
  @moduledoc """
  Stripe Connect, in the demo shop: the shop acts as a platform whose sellers each have a
  connected account. Make a test Express account (`MishkaPay.create_connected_account/1`), list
  the platform's accounts (`MishkaPay.list_connected_accounts/3`) and open one's onboarding page
  (`MishkaPay.account_link/1`), where the seller fills in what Stripe needs.

  A site of a real platform would then answer the platform's key with that account as its
  `:account_id` (`MishkaPay.Credentials`), so its payments run on the seller's account.

  Nothing is read when the page opens: "Show Connect" reads the accounts in the background
  (`start_async`), and "Read again" reads them once more. A sandbox that has not signed up for
  Connect says so plainly.
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open?: false,
       reading?: false,
       accounts: [],
       link: nil,
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

  def handle_event("create", params, socket) do
    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      type: :express,
      country: params["country"],
      email: blank(params["email"]),
      capabilities: ["card_payments", "transfers"],
      reference: "shop-seller-#{System.unique_integer([:positive])}"
    }

    case MishkaPay.create_connected_account(attrs) do
      {:ok, account} ->
        {:noreply,
         socket
         |> update(
           :accounts,
           &[account | Enum.reject(&1, fn known -> known.id == account.id end)]
         )
         |> done("Account #{account.id} made. Open its onboarding page to fill it in.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  def handle_event("onboard", %{"id" => id}, socket) do
    base = ShopWeb.Endpoint.url()

    case MishkaPay.account_link(%{
           provider: "stripe",
           tenant: socket.assigns.tenant,
           account_id: id,
           refresh_url: base <> "/?connect=again",
           return_url: base <> "/?connect=done"
         }) do
      {:ok, link} ->
        {:noreply, socket |> assign(link: link) |> done("Onboarding link for #{id}.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  @impl true
  def handle_async(:connect, {:ok, {:ok, %MishkaPay.Page{items: accounts}}}, socket),
    do: {:noreply, assign(socket, reading?: false, accounts: accounts)}

  def handle_async(:connect, {:ok, {:error, error}}, socket),
    do: {:noreply, socket |> assign(reading?: false) |> failed(error)}

  def handle_async(:connect, {:exit, reason}, socket),
    do: {:noreply, assign(socket, reading?: false, error: inspect(reason), notice: nil)}

  defp read(socket) do
    tenant = socket.assigns.tenant

    socket
    |> assign(reading?: true, error: nil)
    |> start_async(:connect, fn ->
      MishkaPay.list_connected_accounts("stripe", tenant, limit: 20)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="connect" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <.section_title icon="hero-building-storefront" title="Connect: sellers" />
        <button
          :if={!@open?}
          class="btn btn-sm"
          phx-click="show"
          phx-target={@myself}
          data-testid="connect-show"
        >
          Show Connect
        </button>
        <button
          :if={@open?}
          class="btn btn-sm btn-ghost"
          phx-click="read"
          phx-target={@myself}
          disabled={@reading?}
          data-testid="connect-read"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Read again
        </button>
      </div>
      <p class="text-sm opacity-70">
        The shop as a platform: each seller gets a connected account, and a site that names it as
        its account_id takes payments on it.
      </p>
      <.hint>
        MishkaPay.create_connected_account/1, list_connected_accounts/3, account_link/1
      </.hint>

      <div :if={@notice} role="status" class="alert alert-success py-2" data-testid="connect-notice">
        {@notice}
      </div>
      <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="connect-error">
        {@error}
      </div>
      <span
        :if={@reading?}
        class="loading loading-spinner loading-sm"
        data-testid="connect-reading"
      ></span>

      <div :if={@open?} class="space-y-4">
        <form
          id="connect-create-form"
          phx-submit="create"
          phx-target={@myself}
          class="card bg-base-200"
          data-testid="connect-create-form"
        >
          <div class="card-body gap-3">
            <h3 class="font-medium">A test Express account</h3>
            <div class="grid gap-3 sm:grid-cols-3">
              <label class="fieldset">
                <span class="fieldset-legend">Seller's email</span>
                <input
                  name="email"
                  type="email"
                  placeholder="seller@example.com"
                  class="input input-sm"
                  data-testid="connect-email"
                />
              </label>
              <label class="fieldset">
                <span class="fieldset-legend">Country</span>
                <select name="country" class="select select-sm" data-testid="connect-country">
                  <option value="US">United States</option>
                  <option value="GB">United Kingdom</option>
                  <option value="DE">Germany</option>
                </select>
              </label>
              <div class="flex items-end">
                <button
                  class="btn btn-sm btn-primary"
                  phx-disable-with="Asking Stripe..."
                  data-testid="connect-create"
                >
                  Make account
                </button>
              </div>
            </div>
          </div>
        </form>

        <div :if={@link} class="alert py-2" data-testid="connect-link">
          <span>Onboarding for {@link.account_id}:</span>
          <a
            href={@link.url}
            target="_blank"
            rel="noopener"
            class="link link-primary"
            data-testid="connect-link-url"
          >
            open Stripe's onboarding page
          </a>
        </div>

        <div :if={!@reading?} class="overflow-x-auto rounded-box border border-base-300">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Account</th>
                <th>Email</th>
                <th>Payments</th>
                <th>Payouts</th>
                <th>Stripe still needs</th>
                <th></th>
              </tr>
            </thead>
            <tbody data-testid="connect-account-rows">
              <tr :if={@accounts == []}>
                <td colspan="6" class="text-center opacity-70" data-testid="connect-accounts-empty">
                  No connected accounts yet.
                </td>
              </tr>
              <tr
                :for={account <- @accounts}
                data-testid="connect-account-row"
                data-account-id={account.id}
              >
                <td class="font-mono text-xs">{account.id}</td>
                <td>{account.email}</td>
                <td data-testid="connect-account-charges">{yes_no(account.charges_enabled)}</td>
                <td data-testid="connect-account-payouts">{yes_no(account.payouts_enabled)}</td>
                <td class="text-xs" data-testid="connect-account-due">
                  {length(account.requirements_due)} item(s)
                </td>
                <td>
                  <button
                    class="btn btn-xs btn-outline"
                    phx-click="onboard"
                    phx-value-id={account.id}
                    phx-target={@myself}
                    phx-disable-with="Asking Stripe..."
                    data-testid="connect-account-onboard"
                  >
                    Onboarding link
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end

  defp yes_no(true), do: "yes"
  defp yes_no(_no), do: "no"

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank(_none), do: nil

  defp done(socket, message), do: assign(socket, notice: message, error: nil)

  defp failed(socket, error), do: assign(socket, error: MishkaPay.Ash.message(error), notice: nil)
end

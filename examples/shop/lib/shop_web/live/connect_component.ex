defmodule ShopWeb.ConnectComponent do
  @moduledoc """
  Stripe Connect, in the demo shop: the shop acts as a platform whose sellers each have a
  connected account. Make a test Express account (`MishkaPay.create_connected_account/1`), list
  the platform's accounts (`MishkaPay.list_connected_accounts/3`) and open one's onboarding page
  (`MishkaPay.account_link/1`), where the seller fills in what Stripe needs. Send one money
  from the platform's balance (`MishkaPay.create_transfer/1`) and take it back
  (`MishkaPay.reverse_transfer/4`); read the platform's payouts (`MishkaPay.list_payouts/3`) and
  its cut of sellers' sales (`MishkaPay.list_application_fees/3`).

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
       transfers: [],
       payouts: [],
       fees: [],
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

  def handle_event("transfer", params, socket) do
    case MishkaPay.create_transfer(%{
           provider: "stripe",
           tenant: socket.assigns.tenant,
           amount: %{amount: String.trim(params["amount"] || ""), currency: params["currency"]},
           destination: params["destination"],
           description: blank(params["description"]),
           reference: "shop-transfer-#{System.unique_integer([:positive])}"
         }) do
      {:ok, transfer} ->
        {:noreply,
         socket
         |> update(:transfers, &[transfer | &1])
         |> done("Sent #{money(transfer.amount)} to #{transfer.destination} (#{transfer.id}).")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  def handle_event("reverse", %{"id" => id}, socket) do
    case MishkaPay.reverse_transfer("stripe", id, socket.assigns.tenant,
           reference: "shop-undo-#{id}"
         ) do
      {:ok, transfer} ->
        {:noreply,
         socket
         |> update(:transfers, fn all -> Enum.map(all, &((&1.id == id && transfer) || &1)) end)
         |> done("Took back #{money(transfer.amount_reversed)} of #{id}.")}

      {:error, error} ->
        {:noreply, failed(socket, error)}
    end
  end

  @impl true
  def handle_async(:connect, {:ok, {:ok, lists}}, socket),
    do: {:noreply, assign(socket, Map.put(lists, :reading?, false))}

  def handle_async(:connect, {:ok, {:error, error}}, socket),
    do: {:noreply, socket |> assign(reading?: false) |> failed(error)}

  def handle_async(:connect, {:exit, reason}, socket),
    do: {:noreply, assign(socket, reading?: false, error: inspect(reason), notice: nil)}

  # The platform's sellers, the money it sent them, its payouts and its cut, read in the
  # background, one page each.
  defp read(socket) do
    tenant = socket.assigns.tenant

    socket
    |> assign(reading?: true, error: nil)
    |> start_async(:connect, fn ->
      with {:ok, %{items: accounts}} <-
             MishkaPay.list_connected_accounts("stripe", tenant, limit: 20),
           {:ok, %{items: transfers}} <- MishkaPay.list_transfers("stripe", tenant, limit: 10),
           {:ok, %{items: payouts}} <- MishkaPay.list_payouts("stripe", tenant, limit: 10),
           {:ok, %{items: fees}} <- MishkaPay.list_application_fees("stripe", tenant, limit: 10) do
        {:ok, %{accounts: accounts, transfers: transfers, payouts: payouts, fees: fees}}
      end
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
        MishkaPay.create_connected_account/1, list_connected_accounts/3, account_link/1,
        create_transfer/1, reverse_transfer/4, list_transfers/3, list_payouts/3,
        list_application_fees/3
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

        <form
          :if={!@reading? and @accounts != []}
          id="connect-transfer-form"
          phx-submit="transfer"
          phx-target={@myself}
          class="card bg-base-200"
          data-testid="connect-transfer-form"
        >
          <div class="card-body gap-3">
            <h3 class="font-medium">Send a seller money from the platform's balance</h3>
            <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
              <label class="fieldset">
                <span class="fieldset-legend">To</span>
                <select
                  name="destination"
                  class="select select-sm"
                  data-testid="connect-transfer-destination"
                >
                  <option :for={account <- @accounts} value={account.id}>{account.id}</option>
                </select>
              </label>
              <label class="fieldset">
                <span class="fieldset-legend">Amount</span>
                <input
                  name="amount"
                  value="5.00"
                  type="number"
                  step="0.01"
                  min="0.01"
                  class="input input-sm"
                  data-testid="connect-transfer-amount"
                />
              </label>
              <label class="fieldset">
                <span class="fieldset-legend">Currency</span>
                <select
                  name="currency"
                  class="select select-sm"
                  data-testid="connect-transfer-currency"
                >
                  <option value="USD">USD</option>
                  <option value="EUR">EUR</option>
                </select>
              </label>
              <label class="fieldset">
                <span class="fieldset-legend">What for</span>
                <input
                  name="description"
                  placeholder="Order 42, seller's share"
                  class="input input-sm"
                  data-testid="connect-transfer-description"
                />
              </label>
              <div class="flex items-end">
                <button
                  class="btn btn-sm btn-primary"
                  phx-disable-with="Asking Stripe..."
                  data-confirm="Send this money to the seller?"
                  data-testid="connect-transfer-send"
                >
                  Send
                </button>
              </div>
            </div>
          </div>
        </form>

        <div :if={!@reading?} class="grid gap-4 lg:grid-cols-3">
          <div class="overflow-x-auto rounded-box border border-base-300">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Transfer</th>
                  <th>To</th>
                  <th>Amount</th>
                  <th>Taken back</th>
                  <th></th>
                </tr>
              </thead>
              <tbody data-testid="connect-transfer-rows">
                <tr :if={@transfers == []}>
                  <td colspan="5" class="text-center opacity-70" data-testid="connect-transfers-empty">
                    No transfers.
                  </td>
                </tr>
                <tr
                  :for={transfer <- @transfers}
                  data-testid="connect-transfer-row"
                  data-transfer-id={transfer.id}
                >
                  <td class="font-mono text-xs">{transfer.id}</td>
                  <td class="font-mono text-xs">{transfer.destination}</td>
                  <td>{money(transfer.amount)}</td>
                  <td data-testid="connect-transfer-reversed">{money(transfer.amount_reversed)}</td>
                  <td>
                    <button
                      :if={!transfer.reversed}
                      class="btn btn-xs btn-ghost"
                      phx-click="reverse"
                      phx-value-id={transfer.id}
                      phx-target={@myself}
                      phx-disable-with="Asking Stripe..."
                      data-confirm="Take all of this transfer back from the seller?"
                      data-testid="connect-transfer-reverse"
                    >
                      Take back
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="overflow-x-auto rounded-box border border-base-300">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Payout</th>
                  <th>Amount</th>
                  <th>State</th>
                  <th>Arrives</th>
                </tr>
              </thead>
              <tbody data-testid="connect-payout-rows">
                <tr :if={@payouts == []}>
                  <td colspan="4" class="text-center opacity-70" data-testid="connect-payouts-empty">
                    No payouts.
                  </td>
                </tr>
                <tr
                  :for={payout <- @payouts}
                  data-testid="connect-payout-row"
                  data-payout-id={payout.id}
                >
                  <td class="font-mono text-xs">{payout.id}</td>
                  <td>{money(payout.amount)}</td>
                  <td data-testid="connect-payout-status">{payout.status}</td>
                  <td>{payout.arrival_at && Calendar.strftime(payout.arrival_at, "%Y-%m-%d")}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="overflow-x-auto rounded-box border border-base-300">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Platform's cut</th>
                  <th>From</th>
                  <th>Amount</th>
                  <th>Given back</th>
                </tr>
              </thead>
              <tbody data-testid="connect-fee-rows">
                <tr :if={@fees == []}>
                  <td colspan="4" class="text-center opacity-70" data-testid="connect-fees-empty">
                    No application fees.
                  </td>
                </tr>
                <tr :for={fee <- @fees} data-testid="connect-fee-row" data-fee-id={fee.id}>
                  <td class="font-mono text-xs">{fee.id}</td>
                  <td class="font-mono text-xs">{fee.account_id}</td>
                  <td data-testid="connect-fee-amount">{money(fee.amount)}</td>
                  <td>{money(fee.amount_refunded)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp money(%Money{} = money), do: Money.to_string!(money)
  defp money(_none), do: "–"

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

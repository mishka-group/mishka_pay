defmodule ShopWeb.AccessComponent do
  @moduledoc """
  The members part of the demo shop: who may read what, by subscription. A member signs in by
  email (`Shop.Accounts.Member`, kept in the session by `ShopWeb.MemberController`); a plan bought
  while signed in runs `Shop.Pay.Payment`'s `:start_checkout` with the member as the actor, so the
  checkout's owner is the member and the subscription row's `user_id` points at them
  (`belongs_to_user` in the `mishka_pay` block). The members-only post opens when
  `MishkaPay.Ash.subscribed?/3` says so; the member's rows show the `:active?`, `:on_trial?` and
  `:canceling?` calculations. The page sends it each changed subscription (`changed`).
  """

  use ShopWeb, :live_component

  require Ash.Query

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  alias Shop.Pay.{Payment, Subscription}

  @impl true
  def update(%{changed: _record}, socket), do: {:ok, assign_access(socket)}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(tenant: assigns.tenant, member: assigns.member)
     |> assign(plans: Enum.filter(Shop.Catalog.all(), &Shop.Catalog.plan?/1))
     |> assign_access()}
  end

  @impl true
  def handle_event(
        "subscribe",
        %{"product" => slug},
        %{assigns: %{member: %{} = member}} = socket
      ) do
    with %{} = product <- Shop.Catalog.fetch(slug),
         true <- Shop.Catalog.plan?(product),
         {:ok, checkout} <- start_checkout(product, member, socket.assigns.tenant) do
      {:noreply, redirect(socket, external: checkout.url)}
    else
      {:error, error} -> {:noreply, say(socket, :error, MishkaPay.Ash.message(error))}
      _not_a_plan -> {:noreply, say(socket, :error, "That plan is not on sale.")}
    end
  end

  def handle_event("subscribe", _params, socket),
    do: {:noreply, say(socket, :error, "Sign in first, so the plan is yours.")}

  def handle_event("check", _params, socket), do: {:noreply, assign_access(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <section id="members" data-testid="members" class="space-y-4">
      <.section_title icon="hero-lock-closed" title="Members and access" />
      <p class="text-sm opacity-70">
        Sign in with any email (a demo, no password), buy a plan as yourself, and the members-only
        post opens. Cancel the plan and it closes again.
      </p>

      <div class="grid gap-4 md:grid-cols-2">
        <div class="rounded-box bg-base-200 p-4 space-y-3" data-testid="member-box">
          <h3 class="font-medium">Who is here</h3>
          <.hint>Shop.Accounts.Member :sign_in, kept in the session</.hint>
          <.form
            :if={!@member}
            for={%{}}
            action={~p"/member"}
            method="post"
            class="join w-full"
            data-testid="member-sign-in-form"
          >
            <input
              name="email"
              type="email"
              required
              placeholder="ada@example.com"
              class="input input-sm join-item min-w-0 flex-1"
              data-testid="member-email"
            />
            <button class="btn btn-sm btn-primary join-item" data-testid="member-sign-in">
              Sign in as
            </button>
          </.form>
          <div :if={@member} class="flex flex-wrap items-center gap-3">
            <span data-testid="member-signed-in">
              Signed in as <strong data-testid="member-current-email">{@member.email}</strong>
            </span>
            <.link
              href={~p"/member"}
              method="delete"
              class="btn btn-ghost btn-sm"
              data-testid="member-sign-out"
            >
              Sign out
            </.link>
          </div>

          <div :if={@member} class="space-y-2" data-testid="member-plans">
            <h4 class="text-sm font-medium">Buy a plan as yourself</h4>
            <.hint>Payment :start_checkout, actor: the member</.hint>
            <div class="flex flex-wrap gap-2">
              <button
                :for={plan <- @plans}
                class="btn btn-sm"
                phx-click="subscribe"
                phx-value-product={plan.slug}
                phx-target={@myself}
                phx-disable-with="Opening Stripe..."
                data-testid="member-subscribe"
                data-product={plan.slug}
              >
                {plan.name} (${plan.price})
              </button>
            </div>
          </div>
        </div>

        <div
          class={[
            "rounded-box p-4 space-y-2 border",
            (@subscribed? && "bg-success/10 border-success/40") || "bg-base-200 border-base-300"
          ]}
          data-testid="members-post"
          data-open={to_string(@subscribed?)}
        >
          <div class="flex items-center gap-2">
            <h3 class="font-medium flex-1">Members-only post</h3>
            <button
              class="btn btn-ghost btn-xs"
              phx-click="check"
              phx-target={@myself}
              data-testid="members-post-check"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Check again
            </button>
          </div>
          <.hint>MishkaPay.Ash.subscribed?(Shop.Pay.Subscription, member, tenant: tenant)</.hint>
          <div :if={@subscribed?} data-testid="members-post-text">
            <p class="font-medium">How the shop keeps a webhook once</p>
            <p class="text-sm">
              Each event is stored by its id before any work starts, so the same event sent twice is
              worked once. Thanks for being a member.
            </p>
          </div>
          <p :if={!@subscribed?} class="text-sm opacity-70" data-testid="members-post-locked">
            {if @member,
              do: "Locked: you have no plan that gives access now. Buy one on the left.",
              else: "Locked: sign in and buy a plan to read it."}
          </p>
        </div>
      </div>

      <div
        :if={@member}
        class="overflow-x-auto rounded-box border border-base-300"
        data-testid="member-subscriptions"
      >
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Your subscription</th>
              <th>Status</th>
              <th>active?</th>
              <th>on_trial?</th>
              <th>canceling?</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@rows == []}>
              <td colspan="5" class="text-center opacity-70">No subscriptions of yours yet.</td>
            </tr>
            <tr
              :for={row <- @rows}
              data-testid="member-subscription-row"
              data-subscription-id={row.provider_id}
            >
              <td>
                <div class="font-medium">{row.plan || "Subscription"}</div>
                <div class="text-xs opacity-60 font-mono">{row.provider_id}</div>
              </td>
              <td><span class="badge badge-sm">{row.status}</span></td>
              <td data-testid="member-sub-active">{yes_no(row.active?)}</td>
              <td data-testid="member-sub-on-trial">{yes_no(row.on_trial?)}</td>
              <td data-testid="member-sub-canceling">{yes_no(row.canceling?)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  # A plan bought by the signed-in member: the actor becomes the checkout's owner.
  defp start_checkout(product, member, tenant) do
    checkout = %{
      provider: "stripe",
      tenant: tenant,
      mode: :subscription,
      trial_days: product.trial_days,
      items: [item(product)],
      success_url: url(~p"/") <> "?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: url(~p"/?canceled=1"),
      reference: Shop.Catalog.reference(product),
      customer: %{email: member.email}
    }

    Payment
    |> Ash.ActionInput.for_action(:start_checkout, %{checkout: checkout}, actor: member)
    |> Ash.run_action(authorize?: false)
  end

  defp item(%{stripe_price_id: price_id}) when is_binary(price_id),
    do: %{id: price_id, quantity: 1}

  defp item(product) do
    %{
      name: product.name,
      quantity: 1,
      amount: %{amount: product.price, currency: "USD"},
      tax_code: product.tax_code,
      interval: product.interval,
      interval_count: product.interval_count
    }
  end

  defp assign_access(%{assigns: %{member: nil}} = socket),
    do: assign(socket, subscribed?: false, rows: [])

  defp assign_access(%{assigns: %{member: member, tenant: tenant}} = socket) do
    rows =
      Subscription
      |> Ash.Query.filter(user_id == ^member.id and tenant == ^tenant)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.load([:active?, :on_trial?, :canceling?])
      |> Ash.read!(authorize?: false)

    assign(socket,
      subscribed?: MishkaPay.Ash.subscribed?(Subscription, member, tenant: tenant),
      rows: rows
    )
  end

  defp yes_no(true), do: "yes"
  defp yes_no(_no), do: "no"

  defp say(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end
end

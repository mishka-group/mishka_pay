# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Subscription.Sync do
    @moduledoc """
    Reads a subscription from its provider before the action's transaction starts and writes what
    the provider said; after the transaction, fires `mishka_pay:subscription:changed`. A
    subscription the provider cannot give is an error on the action, and nothing is written.
    """

    use Ash.Resource.Change

    alias MishkaPay.{Events, Subscription}
    alias MishkaPay.Helpers.Plugins

    @impl true
    def change(changeset, opts, _context) do
      MishkaPay.Ash.provider_change(changeset, opts, &fetch/1, &announce/2)
    end

    defp fetch(changeset) do
      {provider, subscription_id, tenant} = MishkaPay.Ash.object_ref(changeset, :subscription_id)

      changeset
      |> Ash.Changeset.force_change_attribute(:tenant, tenant)
      |> write(MishkaPay.fetch_subscription(provider, subscription_id, tenant))
    end

    @doc false
    def write(changeset, {:ok, %Subscription{} = subscription}) do
      changeset
      |> Ash.Changeset.force_change_attributes(attributes(subscription))
      |> MishkaPay.Ash.Owner.write(subscription.owner)
      |> Ash.Changeset.put_context(:mishka_pay_subscription, subscription)
    end

    def write(changeset, {:error, error}),
      do: Ash.Changeset.add_error(changeset, MishkaPay.Ash.to_ash_error(error))

    # What one period costs: every item's price times its quantity, in the first item's currency
    # (a provider bills a subscription in one currency); how often, from the first item.
    defp attributes(subscription) do
      first = List.first(subscription.items) || %MishkaPay.Price{}

      %{
        provider: subscription.provider,
        provider_id: subscription.id,
        status: subscription.status,
        plan:
          subscription.items |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1) |> Enum.join(", "),
        price_ids: ids(subscription.items, :id),
        product_ids: ids(subscription.items, :product_id),
        amount: total(subscription.items),
        currency: first.amount && to_string(first.amount.currency),
        interval: first.interval,
        interval_count: first.interval_count,
        quantity: first.quantity,
        pause_behavior: subscription.pause_behavior,
        resumes_at: subscription.resumes_at,
        current_period_end: subscription.current_period_end,
        cancel_at_period_end: subscription.cancel_at_period_end,
        canceled_at: subscription.canceled_at,
        trial_end: subscription.trial_end,
        customer_id: subscription.customer_id,
        customer_email: subscription.customer_email,
        customer_name: subscription.customer_name,
        card_brand: subscription.card_brand,
        card_last4: subscription.card_last4,
        card_exp_month: subscription.card_exp_month,
        card_exp_year: subscription.card_exp_year,
        reference: subscription.reference,
        provider_created_at: subscription.created_at,
        synced_at: DateTime.utc_now()
      }
    end

    defp ids(items, field),
      do: items |> Enum.map(&Map.get(&1, field)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    defp total([]), do: nil

    defp total(items) do
      Enum.reduce(items, Decimal.new(0), fn item, sum ->
        Decimal.add(sum, Decimal.mult(item.amount.amount, item.quantity || 1))
      end)
    end

    # The answer of the listeners does not change the sync: it already happened.
    @doc false
    def announce(
          %{context: %{mishka_pay_subscription: %Subscription{} = subscription}},
          {:ok, record} = result
        ) do
      timeout = Application.get_env(:mishka_pay, :subscription_changed_timeout, 5_000)
      state = %{subscription: subscription, record: record}
      _answer = Plugins.call(Events.subscription_changed(), state, timeout)
      result
    end

    def announce(_changeset, error), do: error
  end
end

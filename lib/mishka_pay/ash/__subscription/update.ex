# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Subscription.Update do
    @moduledoc """
    The `:cancel`, `:resume`, `:change`, `:pause` and `:resume_collection` actions of
    the `:subscription` kind of `MishkaPay.Ash.Resource`: asks the provider before
    the transaction starts, writes the subscription as the provider answers it, and fires
    `mishka_pay:subscription:changed` after.
    """

    use Ash.Resource.Change

    alias MishkaPay.Ash.Subscription.Sync

    @change [
      :price_id,
      :quantity,
      :item_id,
      :proration,
      :proration_date,
      :billing_cycle_anchor,
      :payment_behavior
    ]

    @impl true
    def change(changeset, opts, _context) do
      changeset
      |> Ash.Changeset.before_transaction(&ask(&1, opts[:operation]))
      |> MishkaPay.Ash.announce(opts, &Sync.announce/2)
    end

    defp ask(%{data: row} = changeset, :cancel) do
      at = Ash.Changeset.get_argument(changeset, :at)

      Sync.write(
        changeset,
        MishkaPay.cancel_subscription(row.provider, row.provider_id, row.tenant, at: at)
      )
    end

    defp ask(%{data: row} = changeset, :resume),
      do:
        Sync.write(
          changeset,
          MishkaPay.resume_subscription(row.provider, row.provider_id, row.tenant)
        )

    defp ask(%{data: row} = changeset, :change) do
      options =
        for name <- @change,
            value = Ash.Changeset.get_argument(changeset, name),
            not is_nil(value),
            into: %{},
            do: {name, value}

      attrs =
        Map.merge(options, %{
          provider: row.provider,
          tenant: row.tenant,
          subscription_id: row.provider_id
        })

      Sync.write(changeset, MishkaPay.change_subscription(attrs))
    end

    defp ask(%{data: row} = changeset, :pause) do
      opts = [
        behavior: Ash.Changeset.get_argument(changeset, :behavior),
        resumes_at: Ash.Changeset.get_argument(changeset, :resumes_at)
      ]

      Sync.write(
        changeset,
        MishkaPay.pause_collection(row.provider, row.provider_id, row.tenant, opts)
      )
    end

    defp ask(%{data: row} = changeset, :resume_collection),
      do:
        Sync.write(
          changeset,
          MishkaPay.resume_collection(row.provider, row.provider_id, row.tenant)
        )
  end
end

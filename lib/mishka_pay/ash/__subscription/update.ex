# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Subscription.Update do
    @moduledoc """
    The `:cancel` and `:resume` actions of `MishkaPay.Ash.Subscription`: asks the provider before
    the transaction starts, writes the subscription as the provider answers it, and fires
    `mishka_pay:subscription:changed` after.
    """

    use Ash.Resource.Change

    alias MishkaPay.Ash.Subscription.Sync

    @impl true
    def change(changeset, opts, _context) do
      changeset
      |> Ash.Changeset.before_transaction(&ask(&1, opts[:operation]))
      |> Ash.Changeset.after_transaction(&Sync.announce/2)
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
  end
end

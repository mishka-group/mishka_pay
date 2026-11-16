# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Dispute.Sync do
    @moduledoc """
    The `:sync`, `:submit_evidence` and `:accept` actions of the `:dispute` kind
    (`MishkaPay.Ash.Resource`): asks the
    provider before the action's transaction starts, writes the dispute as the provider answered
    it, and fires `mishka_pay:dispute:changed` after. A dispute the provider cannot give is an
    error on the action, and nothing is written.
    """

    use Ash.Resource.Change

    alias MishkaPay.{Dispute, Events}
    alias MishkaPay.Helpers.Plugins

    @impl true
    def change(changeset, opts, _context) do
      changeset
      |> Ash.Changeset.before_transaction(&ask(&1, opts[:operation]))
      |> MishkaPay.Ash.announce(opts, &announce/2)
    end

    defp ask(changeset, :sync) do
      [provider, id] =
        Enum.map([:provider, :dispute_id], &Ash.Changeset.get_argument(changeset, &1))

      tenant = MishkaPay.Ash.Tenant.of(changeset)

      changeset
      |> Ash.Changeset.force_change_attributes(%{
        provider: provider,
        provider_id: id,
        tenant: tenant
      })
      |> write(MishkaPay.fetch_dispute(provider, id, tenant))
    end

    defp ask(%{data: row} = changeset, :submit_evidence) do
      evidence = Ash.Changeset.get_argument(changeset, :evidence)

      write(
        changeset,
        MishkaPay.update_dispute(%{
          provider: row.provider,
          tenant: row.tenant,
          dispute_id: row.provider_id,
          evidence: Map.new(evidence, fn {key, value} -> {to_string(key), value} end),
          submit: Ash.Changeset.get_argument(changeset, :submit)
        })
      )
    end

    defp ask(%{data: row} = changeset, :accept),
      do: write(changeset, MishkaPay.accept_dispute(row.provider, row.provider_id, row.tenant))

    defp write(changeset, {:ok, %Dispute{} = dispute}) do
      changeset
      |> Ash.Changeset.force_change_attributes(attributes(dispute))
      |> Ash.Changeset.put_context(:mishka_pay_dispute, dispute)
    end

    defp write(changeset, {:error, error}),
      do: Ash.Changeset.add_error(changeset, MishkaPay.Ash.to_ash_error(error))

    defp attributes(dispute) do
      %{
        payment_id: dispute.payment_id,
        charge_id: dispute.charge_id,
        amount: dispute.amount && dispute.amount.amount,
        currency: dispute.amount && to_string(dispute.amount.currency),
        status: dispute.status,
        reason: dispute.reason,
        evidence_due_by: dispute.evidence_due_by,
        has_evidence: dispute.has_evidence,
        submission_count: dispute.submission_count,
        refundable: dispute.refundable,
        provider_created_at: dispute.created_at,
        synced_at: DateTime.utc_now()
      }
    end

    # The answer of the listeners does not change the write: it already happened.
    defp announce(%{context: %{mishka_pay_dispute: %Dispute{} = dispute}}, {:ok, record} = result) do
      timeout = Application.get_env(:mishka_pay, :dispute_changed_timeout, 5_000)

      _answer =
        Plugins.call(Events.dispute_changed(), %{dispute: dispute, record: record}, timeout)

      result
    end

    defp announce(_changeset, result), do: result
  end
end

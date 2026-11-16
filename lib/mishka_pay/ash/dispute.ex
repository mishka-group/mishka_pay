# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Dispute do
    @moduledoc """
    Disputes as an Ash resource fragment: a host keeps its own copy of each chargeback, read
    again from the provider whenever something happens to it.

        defmodule MyApp.Pay.Dispute do
          use Ash.Resource,
            domain: MyApp.Pay,
            data_layer: AshPostgres.DataLayer,
            fragments: [MishkaPay.Ash.Dispute]

          postgres do
            table "pay_disputes"
            repo MyApp.Repo
          end
        end

    and keeps it current from the webhook inbox (`MishkaPay.Ash.Inbox`) with
    `MishkaPay.Ash.Dispute.Listener` (`charge.dispute.*` events).

    ## What it holds

    The provider and its dispute id, the tenant, the payment and charge it takes back, the
    `:amount` and `:currency` (with the `:money` calculation), its `:status` (see
    `MishkaPay.Dispute`), the bank's `:reason`, when evidence is due (`:evidence_due_by`),
    whether evidence was sent (`:has_evidence`, `:submission_count`), whether the payment can still
    be refunded (`:refundable`), when the provider made it and when it was last synced. An
    identity on provider and dispute id keeps one row per dispute.

    ## Actions

      * `:sync` takes `:provider`, `:dispute_id` and `:tenant` and writes what the provider says
        (`MishkaPay.fetch_dispute/3`).
      * `:submit_evidence` sends `:evidence` (the provider's own field names, string to string),
        and to the bank at once with `submit: true` (`MishkaPay.update_dispute/1`).
      * `:accept` accepts the loss (`MishkaPay.accept_dispute/3`).

    After each, `mishka_pay:dispute:changed` (`MishkaPay.Events.dispute_changed/0`) is fired with
    the dispute and the row.
    """

    use Spark.Dsl.Fragment, of: Ash.Resource

    @synced [
      :payment_id,
      :charge_id,
      :amount,
      :currency,
      :status,
      :reason,
      :evidence_due_by,
      :has_evidence,
      :submission_count,
      :refundable,
      :provider_created_at,
      :synced_at
    ]

    attributes do
      uuid_v7_primary_key :id
      attribute :provider, :string, allow_nil?: false, public?: true
      attribute :provider_id, :string, allow_nil?: false, public?: true
      attribute :tenant, :string, public?: true
      attribute :payment_id, :string, public?: true
      attribute :charge_id, :string, public?: true
      attribute :amount, :decimal, public?: true
      attribute :currency, :string, public?: true

      attribute :status, :atom,
        constraints: [one_of: MishkaPay.Dispute.statuses()],
        public?: true

      attribute :reason, :string, public?: true
      attribute :evidence_due_by, :utc_datetime_usec, public?: true
      attribute :has_evidence, :boolean, allow_nil?: false, default: false, public?: true
      attribute :submission_count, :integer, allow_nil?: false, default: 0, public?: true
      attribute :refundable, :boolean, public?: true
      attribute :provider_created_at, :utc_datetime_usec, public?: true
      attribute :synced_at, :utc_datetime_usec, allow_nil?: false, public?: true
      create_timestamp :inserted_at
      update_timestamp :updated_at
    end

    identities do
      identity :provider_dispute, [:provider, :provider_id]
    end

    calculations do
      calculate :money, :term, {MishkaPay.Ash.Payment.Money, field: :amount}
    end

    actions do
      defaults [:read]

      create :sync do
        accept []
        argument :provider, :string, allow_nil?: false
        argument :dispute_id, :string, allow_nil?: false
        argument :tenant, :string

        upsert? true
        upsert_identity :provider_dispute
        upsert_fields @synced

        change {MishkaPay.Ash.Dispute.Sync, operation: :sync}
      end

      update :submit_evidence do
        require_atomic? false
        argument :evidence, :map, allow_nil?: false
        argument :submit, :boolean, default: false, allow_nil?: false
        change {MishkaPay.Ash.Dispute.Sync, operation: :submit_evidence}
      end

      update :accept do
        require_atomic? false
        change {MishkaPay.Ash.Dispute.Sync, operation: :accept}
      end
    end
  end
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Payment do
    @moduledoc """
    Payments as an Ash resource fragment: a host keeps its own copy of each provider payment in a
    resource of its own domain, read again from the provider whenever something happens to it.

        defmodule MyApp.Pay.Payment do
          use Ash.Resource,
            domain: MyApp.Pay,
            data_layer: AshPostgres.DataLayer,
            fragments: [MishkaPay.Ash.Payment]

          postgres do
            table "pay_payments"
            repo MyApp.Repo
          end
        end

    and keeps it current from the webhook inbox (`MishkaPay.Ash.Inbox`) with
    `MishkaPay.Ash.Payment.Listener`:

        defmodule MyApp.Pay.PaymentSync do
          use MishkaPay.Ash.Payment.Listener, resource: MyApp.Pay.Payment
        end

    ## What it holds

    The provider and its payment id, the tenant, the `:status` (see `MishkaPay.Payment`), the
    `:amount`, `:amount_refunded` and `:currency`, the caller's `:reference` from the checkout, the
    provider's `:customer_id`, when the provider made it and when it was last synced. An identity on
    provider and payment id keeps one row per payment. The `:money` and `:money_refunded`
    calculations give them back as `Money`.

    ## Sync

    `:sync` takes `:provider`, `:payment_id` and `:tenant`, reads the payment from the provider
    (`MishkaPay.fetch_payment/3`) before its transaction starts, and writes what the provider said,
    creating the row the first time. The provider is the source of truth, so events may come twice
    or in any order: every sync writes the payment as it is now. After a sync,
    `mishka_pay:payment:changed` (`MishkaPay.Events.payment_changed/0`) is fired with the payment and
    the row, and the host's Ash notifiers (such as `Ash.Notifier.PubSub`) see the action as usual, so
    an open screen can show the change live.

    A host that keeps tenants apart can add `multitenancy` on the `:tenant` attribute.
    """

    use Spark.Dsl.Fragment, of: Ash.Resource

    @statuses [
      :pending,
      :requires_action,
      :paid,
      :partially_refunded,
      :refunded,
      :failed,
      :canceled
    ]

    attributes do
      uuid_v7_primary_key :id
      attribute :provider, :string, allow_nil?: false, public?: true
      attribute :provider_id, :string, allow_nil?: false, public?: true
      attribute :tenant, :string, public?: true
      attribute :status, :atom, constraints: [one_of: @statuses], allow_nil?: false, public?: true
      attribute :amount, :decimal, allow_nil?: false, public?: true
      attribute :amount_refunded, :decimal, allow_nil?: false, default: 0, public?: true
      attribute :currency, :string, allow_nil?: false, public?: true
      attribute :reference, :string, public?: true
      attribute :customer_id, :string, public?: true
      attribute :provider_created_at, :utc_datetime_usec, public?: true
      attribute :synced_at, :utc_datetime_usec, allow_nil?: false, public?: true
      create_timestamp :inserted_at
      update_timestamp :updated_at
    end

    identities do
      identity :provider_payment, [:provider, :provider_id]
    end

    calculations do
      calculate :money, :term, {MishkaPay.Ash.Payment.Money, field: :amount}
      calculate :money_refunded, :term, {MishkaPay.Ash.Payment.Money, field: :amount_refunded}
    end

    actions do
      defaults [:read]

      create :sync do
        accept []
        argument :provider, :string, allow_nil?: false
        argument :payment_id, :string, allow_nil?: false
        argument :tenant, :string

        upsert? true
        upsert_identity :provider_payment

        upsert_fields [
          :tenant,
          :status,
          :amount,
          :amount_refunded,
          :currency,
          :reference,
          :customer_id,
          :provider_created_at,
          :synced_at
        ]

        change MishkaPay.Ash.Payment.Sync
      end
    end
  end
end

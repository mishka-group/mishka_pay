# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Subscription do
    @moduledoc """
    Subscriptions as an Ash resource fragment: a host keeps its own copy of each provider
    subscription in a resource of its own domain, read again from the provider whenever something
    happens to it.

        defmodule MyApp.Pay.Subscription do
          use Ash.Resource,
            domain: MyApp.Pay,
            data_layer: AshPostgres.DataLayer,
            fragments: [MishkaPay.Ash.Subscription]

          postgres do
            table "pay_subscriptions"
            repo MyApp.Repo
          end
        end

    and keeps it current from the webhook inbox (`MishkaPay.Ash.Inbox`) with
    `MishkaPay.Ash.Subscription.Listener`:

        defmodule MyApp.Pay.SubscriptionSync do
          use MishkaPay.Ash.Subscription.Listener, resource: MyApp.Pay.Subscription
        end

    A subscription starts with a checkout in `mode: :subscription` (the `:start_checkout` action
    of `MishkaPay.Ash.Payment`, or `MishkaPay.checkout/1`).

    ## What it holds

    The provider and its subscription id, the tenant, the `:status` (see `MishkaPay.Subscription`),
    the `:plan` (its items' names), what each period costs (`:amount`, `:currency`, with the
    `:money` calculation) and how often (`:interval`, `:interval_count`), the end of the period paid
    for (`:current_period_end`), whether it ends then (`:cancel_at_period_end`), `:canceled_at`,
    `:trial_end`, the buyer (`:customer_id`, `:customer_email`, `:customer_name`), the caller's
    `:reference`, when the provider made it and when it was last synced. An identity on provider
    and subscription id keeps one row per subscription.

    ## Actions

      * `:sync` takes `:provider`, `:subscription_id` and `:tenant`, reads the subscription
        (`MishkaPay.fetch_subscription/3`) before its transaction starts and writes what the
        provider said; the tenant is kept from the first time.
      * `:cancel` cancels it through its provider (`MishkaPay.cancel_subscription/4`), `at:
        :period_end` (the default) or `:now`, and writes what the provider answered.
      * `:resume` takes back a cancel set for the period's end (`MishkaPay.resume_subscription/3`).

    After each, `mishka_pay:subscription:changed` (`MishkaPay.Events.subscription_changed/0`) is
    fired with the subscription and the row. Errors come back as Ash errors
    (`MishkaPay.Ash.to_ash_error/1`).
    """

    use Spark.Dsl.Fragment, of: Ash.Resource

    @statuses [
      :incomplete,
      :incomplete_expired,
      :trialing,
      :active,
      :past_due,
      :unpaid,
      :paused,
      :canceled
    ]

    attributes do
      uuid_v7_primary_key :id
      attribute :provider, :string, allow_nil?: false, public?: true
      attribute :provider_id, :string, allow_nil?: false, public?: true
      attribute :tenant, :string, public?: true
      attribute :status, :atom, constraints: [one_of: @statuses], allow_nil?: false, public?: true
      attribute :plan, :string, public?: true
      attribute :amount, :decimal, public?: true
      attribute :currency, :string, public?: true

      attribute :interval, :atom,
        constraints: [one_of: [:day, :week, :month, :year]],
        public?: true

      attribute :interval_count, :integer, public?: true
      attribute :current_period_end, :utc_datetime_usec, public?: true
      attribute :cancel_at_period_end, :boolean, allow_nil?: false, default: false, public?: true
      attribute :canceled_at, :utc_datetime_usec, public?: true
      attribute :trial_end, :utc_datetime_usec, public?: true
      attribute :customer_id, :string, public?: true
      attribute :customer_email, :string, public?: true
      attribute :customer_name, :string, public?: true
      attribute :reference, :string, public?: true
      attribute :provider_created_at, :utc_datetime_usec, public?: true
      attribute :synced_at, :utc_datetime_usec, allow_nil?: false, public?: true
      create_timestamp :inserted_at
      update_timestamp :updated_at
    end

    identities do
      identity :provider_subscription, [:provider, :provider_id]
    end

    calculations do
      calculate :money, :term, {MishkaPay.Ash.Payment.Money, field: :amount}
    end

    actions do
      defaults [:read]

      create :sync do
        accept []
        argument :provider, :string, allow_nil?: false
        argument :subscription_id, :string, allow_nil?: false
        argument :tenant, :string

        upsert? true
        upsert_identity :provider_subscription

        upsert_fields [
          :status,
          :plan,
          :amount,
          :currency,
          :interval,
          :interval_count,
          :current_period_end,
          :cancel_at_period_end,
          :canceled_at,
          :trial_end,
          :customer_id,
          :customer_email,
          :customer_name,
          :reference,
          :provider_created_at,
          :synced_at
        ]

        change MishkaPay.Ash.Subscription.Sync
      end

      update :cancel do
        require_atomic? false

        argument :at, :atom,
          constraints: [one_of: [:now, :period_end]],
          default: :period_end,
          allow_nil?: false

        change {MishkaPay.Ash.Subscription.Update, operation: :cancel}
      end

      update :resume do
        require_atomic? false
        change {MishkaPay.Ash.Subscription.Update, operation: :resume}
      end
    end
  end
end

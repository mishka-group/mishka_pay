# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(AshOban) do
  defmodule MishkaPay.Ash.Inbox do
    @moduledoc """
    The webhook inbox, as an Ash resource fragment: every checked provider event is stored once
    and worked by an AshOban job, with retries, so a slow or failing step never loses an event and
    the provider gets its answer at once.

    A project adds it to a resource of its own domain, with its own data layer:

        defmodule MyApp.Pay.WebhookEvent do
          use Ash.Resource,
            domain: MyApp.Pay,
            data_layer: AshPostgres.DataLayer,
            fragments: [MishkaPay.Ash.Inbox]

          postgres do
            table "pay_webhook_events"
            repo MyApp.Repo
          end
        end

    and listens for webhooks with `MishkaPay.Ash.Inbox.Listener`:

        defmodule MyApp.Pay.Inbox do
          use MishkaPay.Ash.Inbox.Listener, resource: MyApp.Pay.WebhookEvent
        end

    Add the queue to Oban, `queues: [mishka_pay_inbox: 10]`, and the resource's domain to
    `AshOban.config/2` like any AshOban resource.

    ## What it holds

    The event's provider, tenant, id, type, object, payment, subscription, mode and time (see
    `MishkaPay.Event`), its `:status` (`:pending`, `:processed`, `:failed`), the `:last_error` (kept
    from each failed try, while it is still tried again) and when it was processed. An
    identity on provider and event id keeps each event once, however often the provider sends it.

    ## How an event is worked

    1. `:receive` stores it (a second delivery finds the first) and starts the `:process` trigger.
    2. `:process` fires `mishka_pay:event:process` (`MishkaPay.Events.event_process/0`) with the
       event, outside the database transaction, in a task that cannot take the job down. A listener
       that sets `:failed`, raises, exits or runs past `config :mishka_pay, event_process_timeout:`
       (30 seconds) leaves the event pending: AshOban tries again, ten times in all.
    3. After the last try, `:fail` marks it `:failed` with the reason, for a person to look at.

    The trigger's worker and scheduler are `MishkaPay.Ash.Inbox.Worker` and
    `MishkaPay.Ash.Inbox.Scheduler`, so a project has one inbox resource.
    """

    use Spark.Dsl.Fragment, of: Ash.Resource, extensions: [AshOban]

    attributes do
      uuid_v7_primary_key :id
      attribute :provider, :string, allow_nil?: false, public?: true
      attribute :tenant, :string, public?: true
      attribute :event_id, :string, allow_nil?: false, public?: true
      attribute :type, :string, allow_nil?: false, public?: true
      attribute :object_id, :string, public?: true
      attribute :object_type, :string, public?: true
      attribute :payment_id, :string, public?: true
      attribute :subscription_id, :string, public?: true
      attribute :livemode, :boolean, allow_nil?: false, default: false, public?: true
      attribute :account, :string, public?: true
      attribute :provider_created_at, :utc_datetime_usec, public?: true

      attribute :status, :atom,
        constraints: [one_of: [:pending, :processed, :failed]],
        allow_nil?: false,
        default: :pending,
        public?: true

      attribute :last_error, :string, public?: true
      attribute :processed_at, :utc_datetime_usec, public?: true
      create_timestamp :inserted_at
      update_timestamp :updated_at
    end

    identities do
      identity :provider_event, [:provider, :event_id]
    end

    actions do
      defaults [:read]

      create :receive do
        accept [
          :provider,
          :tenant,
          :event_id,
          :type,
          :object_id,
          :object_type,
          :payment_id,
          :subscription_id,
          :livemode,
          :account,
          :provider_created_at
        ]

        upsert? true
        upsert_identity :provider_event
        upsert_fields []
        change run_oban_trigger(:process)
      end

      update :process do
        require_atomic? false
        change MishkaPay.Ash.Inbox.Process
      end

      # Keeps why a try failed while the event is still being tried again.
      update :note_error do
        accept [:last_error]
      end

      update :fail do
        require_atomic? false
        argument :error, :term
        change MishkaPay.Ash.Inbox.Fail
      end
    end

    oban do
      triggers do
        trigger :process do
          action :process
          where expr(status == :pending)
          queue :mishka_pay_inbox
          max_attempts 10
          on_error :fail
          worker_module_name MishkaPay.Ash.Inbox.Worker
          scheduler_module_name MishkaPay.Ash.Inbox.Scheduler
        end
      end
    end
  end
end

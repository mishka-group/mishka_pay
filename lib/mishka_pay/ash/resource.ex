# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Resource do
    @mishka_pay %Spark.Dsl.Section{
      name: :mishka_pay,
      describe: """
      What Mishka Pay keeps in this resource: its `kind`, and which of the kind's actions,
      listener, announcements, code interface and user relationship it gets.
      """,
      examples: [
        """
        mishka_pay do
          kind :subscription
          actions [:sync, :cancel]
          belongs_to_user MyApp.Accounts.User
        end
        """
      ],
      no_depend_modules: [:belongs_to_user],
      schema: [
        kind: [
          type: {:one_of, MishkaPay.Ash.Resource.Kinds.kinds()},
          required: true,
          doc: """
          What the resource keeps: `:inbox` (each checked webhook event), `:payment`,
          `:subscription`, `:customer` or `:dispute`.
          """
        ],
        actions: [
          type: {:list, :atom},
          doc: """
          Only these actions of the kind, besides the primary `:read`. Every action of the kind
          when left out. An `:inbox` needs all of its own.
          """
        ],
        listen?: [
          type: :boolean,
          default: true,
          doc: """
          Makes `<Resource>.MishkaPayListener`, the webhook listener that keeps the resource
          current. `MishkaPay.Ash.listeners/1` lists them for the application's children.
          """
        ],
        announce?: [
          type: :boolean,
          default: true,
          doc: """
          Fires `mishka_pay:<kind>:changed` after each write the provider answered. The inbox
          announces nothing either way.
          """
        ],
        code_interface?: [
          type: :boolean,
          default: true,
          doc: """
          Defines a code interface function for each action it adds, such as
          `MyApp.Pay.Subscription.cancel!(row, %{at: :now})`. The inbox's `:receive` is
          `receive_event`.
          """
        ],
        belongs_to_user: [
          type: {:or, [:atom, {:tuple, [:atom, :keyword_list]}]},
          doc: """
          A `:user` belongs_to relationship to the host's user resource, on `:user_id`, or on
          another attribute with `{MyApp.Accounts.User, attribute: :owner_id}`. Rows synced from
          webhooks have no user, so it may be nil.
          """
        ]
      ]
    }

    @moduledoc """
    Mishka Pay's Ash layer as a resource extension: a host's resource, in its own domain and data
    layer, says what it keeps, and gets the attributes, identities, calculations, actions, code
    interface and webhook listener of that kind.

        defmodule MyApp.Pay.Subscription do
          use Ash.Resource,
            domain: MyApp.Pay,
            data_layer: AshPostgres.DataLayer,
            extensions: [MishkaPay.Ash.Resource]

          mishka_pay do
            kind :subscription
          end

          postgres do
            table "pay_subscriptions"
            repo MyApp.Repo
          end
        end

    The application supervises the listeners of the domain's resources:

        children = [MishkaPay.Providers.Stripe, MyApp.Pay.Keys] ++ MishkaPay.Ash.listeners(MyApp.Pay)

    A host owns the tables, the domain, the policies and the notifiers. Anything the host defines
    itself is kept: an attribute, identity, calculation, action, relationship or code interface of
    the same name is never added again, so a host can change one (such as the `:tenant`
    attribute's type). A resource without its own primary key gets `uuid_v7_primary_key :id`, and
    every kind gets the primary `:read` and `:inserted_at`/`:updated_at` timestamps.

    Every action asks the provider before its transaction starts, writes what the provider
    answered and, with `announce? true`, fires `mishka_pay:<kind>:changed` with the provider's
    struct and the row after it. The host's Ash notifiers (such as `Ash.Notifier.PubSub`) see the
    actions as usual, so an open screen can show a change live. Errors come back as Ash errors
    (`MishkaPay.Ash.to_ash_error/1`).

    A host that keeps tenants apart adds Ash multitenancy on its own attribute: each action then
    reads the provider keys of its Ash tenant, and each listener syncs a webhook's row in the
    webhook's own tenant (see `MishkaPay.Ash.Tenant`). The inbox stays global.

    ## `:inbox`

    Every checked provider event is stored once and worked by an AshOban job, with retries, so a
    slow or failing step never loses an event and the provider gets its answer at once. The
    extension adds AshOban to the resource; add the `mishka_pay_inbox` queue to Oban and the
    resource's domain to `AshOban.config/2` like any AshOban resource.

    It holds the event's provider, tenant, id, type, object, payment, subscription, dispute, mode
    and time (see `MishkaPay.Event`), its `:status` (`:pending`, `:processed`, `:failed`), the
    `:last_error` (kept from each failed try, while it is still tried again) and when it was
    processed. An identity on provider and event id keeps each event once, however often the
    provider sends it.

    1. `:receive` stores it (a second delivery finds the first) and starts the `:process` trigger.
    2. `:process` fires `mishka_pay:event:process` (`MishkaPay.Events.event_process/0`) with the
       event, outside the database transaction, in a task that cannot take the job down. A listener
       that sets `:failed`, raises, exits or runs past `config :mishka_pay, event_process_timeout:`
       (30 seconds) leaves the event pending, its reason noted by `:note_error`: AshOban tries
       again, ten times in all.
    3. After the last try, `:fail` marks it `:failed` with the reason, for a person to look at.

    The trigger's worker and scheduler are `<Resource>.MishkaPayWorker` and
    `<Resource>.MishkaPayScheduler`. Its listener stores each event `MishkaPay.Webhook` checked.

    ## `:payment`

    Holds the provider and its payment id, the tenant, the `:status` (see `MishkaPay.Payment`),
    the `:amount`, `:amount_refunded` and `:currency` (the `:money` and `:money_refunded`
    calculations give them as `Money`), the caller's `:reference` from the checkout, the buyer
    (`:customer_id`, `:customer_email`, `:customer_name`), the card (`:card_brand`,
    `:card_last4`), why the last try failed (`:failure_code`, `:failure_message`), whether the
    buyer's bank asked for it back (`:disputed`), when the provider made it and when it was last
    synced. An identity on provider and payment id keeps one row per payment.

      * `:sync` takes `:provider`, `:payment_id` and `:tenant`, reads the payment
        (`MishkaPay.fetch_payment/3`) and writes it, creating the row the first time; the tenant
        is kept from that first time, so a later sync never moves a payment to another tenant.
        Events may come twice or in any order: every sync writes the payment as it is now.
      * `:start_checkout` (generic) opens a checkout (`MishkaPay.checkout/1`) from its `:checkout`
        map and answers the `MishkaPay.Checkout` with the page to send the buyer to. The row
        comes later, from the webhook of the payment the buyer makes.
      * `:refund` refunds the payment through its provider (`MishkaPay.refund/1`), in full or by
        `:amount`, with an optional `:reason` and `:reference`, then syncs the row and keeps the
        `MishkaPay.Refund` in the record's `:refund` metadata. How often a payment may be refunded
        is the tenant's runtime setting (`MishkaPay.Credentials`, `:refunds`). When the refund
        went through but the payment cannot be read again, the row counts the refund itself and
        the next sync brings the provider's word.

    Its listener syncs the payment each inbox event concerns.

    ## `:subscription`

    Holds the provider and its subscription id, the tenant, the `:status` (see
    `MishkaPay.Subscription`), the `:plan` (its items' names), what each period costs (`:amount`,
    `:currency`, with the `:money` calculation) and how often (`:interval`, `:interval_count`),
    how many (`:quantity`), the end of the period paid for (`:current_period_end`), whether it ends
    then (`:cancel_at_period_end`), `:canceled_at`, `:trial_end`, a pause (`:pause_behavior`,
    `:resumes_at`), the buyer, the caller's `:reference`, when the provider made it and when it was
    last synced. A subscription starts with a checkout in `mode: :subscription`.

      * `:sync` takes `:provider`, `:subscription_id` and `:tenant` and writes what the provider
        says (`MishkaPay.fetch_subscription/3`).
      * `:cancel` cancels it (`MishkaPay.cancel_subscription/4`), `at: :period_end` (the default)
        or `:now`; `:resume` takes back a cancel set for the period's end
        (`MishkaPay.resume_subscription/3`).
      * `:change` changes its plan (`:price_id`) or quantity, with every option of
        `MishkaPay.SubscriptionChange` as arguments (`MishkaPay.change_subscription/1`).
      * `:pause` pauses collecting its payments (`behavior:` and `resumes_at:`, see
        `MishkaPay.pause_collection/4`); `:resume_collection` collects again.

    ## `:customer`

    Holds the provider and its customer id, the tenant, `:email`, `:name`, `:phone`, the caller's
    `:reference` (the host's own user id), `:metadata`, the `:default_payment_method`, when the
    provider made it, when it was last synced, and `:deleted_at` once the provider deleted it.

      * `:register` makes the customer at its provider (`MishkaPay.create_customer/1`) from
        `:provider`, `:tenant`, `:email`, `:name`, `:phone`, `:reference` and `:metadata`. The
        same `:reference` and fields registered twice within a day are one customer and one row.
      * `:sync` takes `:provider`, `:customer_id` and `:tenant` (`MishkaPay.fetch_customer/3`). A
        customer the provider deleted keeps its row, with `:deleted_at` set.
      * `:edit` changes `:email`, `:name`, `:phone` or `:metadata` at the provider
        (`MishkaPay.update_customer/1`).
      * `:portal` (generic) takes the row's `:id` and a `:return_url` (and the provider's
        `:configuration`) and answers a `MishkaPay.PortalSession`: redirect the buyer to its
        `:url`, where they manage their cards, invoices and subscriptions.

    ## `:dispute`

    Holds the provider and its dispute id, the tenant, the payment and charge it takes back, the
    `:amount` and `:currency` (with the `:money` calculation), its `:status` (see
    `MishkaPay.Dispute`), the bank's `:reason`, when evidence is due (`:evidence_due_by`), whether
    evidence was sent (`:has_evidence`, `:submission_count`), whether the payment can still be
    refunded (`:refundable`), when the provider made it and when it was last synced.

      * `:sync` takes `:provider`, `:dispute_id` and `:tenant` (`MishkaPay.fetch_dispute/3`).
      * `:submit_evidence` sends `:evidence` (the provider's own field names, string to string),
        and to the bank at once with `submit: true` (`MishkaPay.update_dispute/1`).
      * `:accept` accepts the loss (`MishkaPay.accept_dispute/3`).

    Its listener syncs the dispute of each `charge.dispute.*` event.

    ## Options

    #{Spark.Options.docs(@mishka_pay.schema)}

    `MishkaPay.Ash.Resource.Info` reads them back.
    """

    use Spark.Dsl.Extension,
      sections: [@mishka_pay],
      transformers: [MishkaPay.Ash.Resource.ApplyKind],
      add_extensions: if(Code.ensure_loaded?(AshOban), do: [AshOban], else: [])
  end
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Resource.Kinds do
    @moduledoc """
    The shape of each kind of `MishkaPay.Ash.Resource`, in one place: its attributes, identities,
    calculations and actions (with their arguments, changes and options), the code interface name
    of each action, the listener that keeps it current and, for the inbox, its AshOban trigger.
    `MishkaPay.Ash.Resource.ApplyKind` adds them to a host's resource with `Ash.Resource.Builder`,
    skipping whatever the host defines itself.
    """

    require Ash.Expr

    alias Ash.Resource.Builder

    @type kind :: :inbox | :payment | :subscription | :customer | :dispute
    @type attribute :: {atom(), atom(), keyword()}
    @type action :: {atom(), Ash.Resource.Actions.action_type(), keyword()}

    @kinds [:inbox, :payment, :subscription, :customer, :dispute]

    @payment_statuses [
      :pending,
      :requires_action,
      :paid,
      :partially_refunded,
      :refunded,
      :failed,
      :canceled
    ]

    @subscription_statuses [
      :incomplete,
      :incomplete_expired,
      :trialing,
      :active,
      :past_due,
      :unpaid,
      :paused,
      :canceled
    ]

    @pause_behaviors [:void, :keep_as_draft, :mark_uncollectible]

    # The inbox fields a webhook fills; the rest is the inbox's own bookkeeping.
    @inbox_bookkeeping [:status, :last_error, :processed_at]

    # Every provider object keeps these three; a sync writes all its other attributes.
    @object_keys [:provider, :provider_id, :tenant]

    @doc "Every kind."
    @spec kinds() :: [kind()]
    def kinds, do: @kinds

    @doc "The names of a kind's actions, in the order they are added."
    @spec action_names(kind()) :: [atom()]
    def action_names(kind), do: for({name, _type, _opts} <- actions(kind, []), do: name)

    @doc "The listener macro module that keeps a resource of the kind current from webhooks."
    @spec listener(kind()) :: module()
    def listener(:inbox), do: MishkaPay.Ash.Inbox.Listener
    def listener(:payment), do: MishkaPay.Ash.Payment.Listener
    def listener(:subscription), do: MishkaPay.Ash.Subscription.Listener
    def listener(:customer), do: MishkaPay.Ash.Customer.Listener
    def listener(:dispute), do: MishkaPay.Ash.Dispute.Listener

    @doc """
    The code interface name of an action. `receive` is an Elixir special form, so the inbox's
    `:receive` is `receive_event`.
    """
    @spec interface(atom()) :: atom()
    def interface(:receive), do: :receive_event
    def interface(action), do: action

    @doc "The attributes of a kind, after its `:id` primary key and before its timestamps."
    @spec attributes(kind()) :: [attribute()]
    def attributes(:inbox) do
      [
        {:provider, :string, required()},
        {:tenant, :string, public()},
        {:event_id, :string, required()},
        {:type, :string, required()},
        {:object_id, :string, public()},
        {:object_type, :string, public()},
        {:payment_id, :string, public()},
        {:subscription_id, :string, public()},
        {:dispute_id, :string, public()},
        {:livemode, :boolean, required(default: false)},
        {:account, :string, public()},
        {:provider_created_at, :utc_datetime_usec, public()},
        {:status, :atom,
         required(constraints: [one_of: [:pending, :processed, :failed]], default: :pending)},
        {:last_error, :string, public()},
        {:processed_at, :utc_datetime_usec, public()}
      ]
    end

    def attributes(:payment) do
      object([
        {:status, :atom, required(constraints: [one_of: @payment_statuses])},
        {:amount, :decimal, required()},
        {:amount_refunded, :decimal, required(default: 0)},
        {:currency, :string, required()},
        {:reference, :string, public()},
        {:customer_id, :string, public()},
        {:customer_email, :string, public()},
        {:customer_name, :string, public()},
        {:card_brand, :string, public()},
        {:card_last4, :string, public()},
        {:failure_code, :string, public()},
        {:failure_message, :string, public()},
        {:disputed, :boolean, required(default: false)},
        {:checkout_id, :string, public()},
        {:price_ids, {:array, :string}, required(default: [])},
        {:product_ids, {:array, :string}, required(default: [])}
      ])
    end

    def attributes(:subscription) do
      object([
        {:status, :atom, required(constraints: [one_of: @subscription_statuses])},
        {:plan, :string, public()},
        {:price_ids, {:array, :string}, required(default: [])},
        {:product_ids, {:array, :string}, required(default: [])},
        {:amount, :decimal, public()},
        {:currency, :string, public()},
        {:interval, :atom, public(constraints: [one_of: [:day, :week, :month, :year]])},
        {:interval_count, :integer, public()},
        {:quantity, :integer, public()},
        {:pause_behavior, :atom, public(constraints: [one_of: @pause_behaviors])},
        {:resumes_at, :utc_datetime_usec, public()},
        {:current_period_end, :utc_datetime_usec, public()},
        {:cancel_at_period_end, :boolean, required(default: false)},
        {:canceled_at, :utc_datetime_usec, public()},
        {:trial_end, :utc_datetime_usec, public()},
        {:customer_id, :string, public()},
        {:customer_email, :string, public()},
        {:customer_name, :string, public()},
        {:reference, :string, public()}
      ])
    end

    def attributes(:customer) do
      object([
        {:email, :string, public()},
        {:name, :string, public()},
        {:phone, :string, public()},
        {:reference, :string, public()},
        {:metadata, :map, required(default: %{})},
        {:default_payment_method, :string, public()},
        {:deleted_at, :utc_datetime_usec, public()}
      ])
    end

    def attributes(:dispute) do
      object([
        {:payment_id, :string, public()},
        {:charge_id, :string, public()},
        {:amount, :decimal, public()},
        {:currency, :string, public()},
        {:status, :atom, public(constraints: [one_of: MishkaPay.Dispute.statuses()])},
        {:reason, :string, public()},
        {:evidence_due_by, :utc_datetime_usec, public()},
        {:has_evidence, :boolean, required(default: false)},
        {:submission_count, :integer, required(default: 0)},
        {:refundable, :boolean, public()}
      ])
    end

    @doc "The identity that keeps each provider object (or event) once."
    @spec identity(kind()) :: {atom(), [atom()]}
    def identity(:inbox), do: {:provider_event, [:provider, :event_id]}
    def identity(:payment), do: {:provider_payment, [:provider, :provider_id]}
    def identity(:subscription), do: {:provider_subscription, [:provider, :provider_id]}
    def identity(:customer), do: {:provider_customer, [:provider, :provider_id]}
    def identity(:dispute), do: {:provider_dispute, [:provider, :provider_id]}

    @doc "The calculations of a kind: its amounts as `Money`."
    @spec calculations(kind()) :: [{atom(), atom(), {module(), keyword()}}]
    def calculations(:payment),
      do: [money(:money, :amount), money(:money_refunded, :amount_refunded)]

    def calculations(kind) when kind in [:subscription, :dispute], do: [money(:money, :amount)]
    def calculations(_kind), do: []

    @doc """
    The actions of a kind. `announce?: false` builds their changes without the
    `mishka_pay:<kind>:changed` event; `user:` names the `belongs_to_user` attribute, which a sync
    writes from the owner and a customer's `:register` accepts.
    """
    @spec actions(kind(), keyword()) :: [action()]
    def actions(:inbox, _opts) do
      fields =
        for {name, _type, _opts} <- attributes(:inbox), name not in @inbox_bookkeeping, do: name

      [
        {:receive, :create,
         [
           accept: fields,
           upsert?: true,
           upsert_identity: :provider_event,
           upsert_fields: [],
           changes: [
             change({AshOban.Changes.RunObanTrigger, trigger: :process, oban_job_opts: []})
           ]
         ]},
        {:process, :update,
         [require_atomic?: false, changes: [change(MishkaPay.Ash.Inbox.Process)]]},
        {:note_error, :update, [accept: [:last_error]]},
        {:fail, :update,
         [
           require_atomic?: false,
           arguments: [argument(:error, :term)],
           changes: [change(MishkaPay.Ash.Inbox.Fail)]
         ]}
      ]
    end

    def actions(:payment, opts) do
      [
        sync(:payment, :payment_id, {MishkaPay.Ash.Payment.Sync, announce(opts)}, opts[:user]),
        {:start_checkout, :action,
         [
           returns: :struct,
           constraints: [instance_of: MishkaPay.Checkout],
           arguments: [argument(:checkout, :map, allow_nil?: false)],
           run: MishkaPay.Ash.Payment.StartCheckout
         ]},
        update(:refund, {MishkaPay.Ash.Payment.Refund, announce(opts)}, [
          argument(:amount, :term),
          argument(:reason, :atom,
            constraints: [one_of: [:requested_by_customer, :duplicate, :fraudulent]]
          ),
          argument(:reference, :string)
        ])
      ]
    end

    def actions(:subscription, opts) do
      [
        sync(
          :subscription,
          :subscription_id,
          {MishkaPay.Ash.Subscription.Sync, announce(opts)},
          opts[:user]
        ),
        subscription_update(:cancel, opts, [
          argument(:at, :atom,
            constraints: [one_of: [:now, :period_end]],
            default: :period_end,
            allow_nil?: false
          )
        ]),
        subscription_update(:resume, opts, []),
        subscription_update(:change, opts, [
          argument(:price_id, :string),
          argument(:quantity, :integer, constraints: [min: 1]),
          argument(:item_id, :string),
          argument(:proration, :atom,
            constraints: [one_of: [:create_prorations, :always_invoice, :none]]
          ),
          argument(:proration_date, :utc_datetime),
          argument(:billing_cycle_anchor, :atom, constraints: [one_of: [:now, :unchanged]]),
          argument(:payment_behavior, :atom,
            constraints: [
              one_of: [
                :allow_incomplete,
                :error_if_incomplete,
                :pending_if_incomplete,
                :default_incomplete
              ]
            ]
          )
        ]),
        subscription_update(:pause, opts, [
          argument(:behavior, :atom,
            constraints: [one_of: @pause_behaviors],
            default: :void,
            allow_nil?: false
          ),
          argument(:resumes_at, :utc_datetime)
        ]),
        subscription_update(:resume_collection, opts, [])
      ]
    end

    def actions(:customer, opts) do
      change = &{MishkaPay.Ash.Customer.Sync, [operation: &1] ++ announce(opts)}

      [
        {:register, :create,
         upsert(:customer,
           accept: List.wrap(opts[:user]),
           arguments: [
             argument(:provider, :string, allow_nil?: false),
             argument(:tenant, :string),
             argument(:email, :string),
             argument(:name, :string),
             argument(:phone, :string),
             argument(:reference, :string),
             argument(:metadata, :map)
           ],
           changes: [change(change.(:register))]
         )},
        sync(:customer, :customer_id, change.(:sync)),
        update(
          :edit,
          change.(:edit),
          [
            argument(:email, :string),
            argument(:name, :string),
            argument(:phone, :string),
            argument(:metadata, :map)
          ],
          accept: []
        ),
        {:portal, :action,
         [
           returns: :struct,
           constraints: [instance_of: MishkaPay.PortalSession],
           arguments: [
             argument(:id, :uuid, allow_nil?: false),
             argument(:return_url, :string, allow_nil?: false),
             argument(:configuration, :string)
           ],
           run: MishkaPay.Ash.Customer.Portal
         ]}
      ]
    end

    def actions(:dispute, opts) do
      change = &{MishkaPay.Ash.Dispute.Sync, [operation: &1] ++ announce(opts)}

      [
        sync(:dispute, :dispute_id, change.(:sync)),
        update(:submit_evidence, change.(:submit_evidence), [
          argument(:evidence, :map, allow_nil?: false),
          argument(:submit, :boolean, default: false, allow_nil?: false)
        ]),
        update(:accept, change.(:accept), [])
      ]
    end

    @doc """
    The inbox's AshOban trigger, as `oban do triggers do trigger :process ... end end` writes it.
    Its worker and scheduler are named after the resource, so two inboxes never share them.
    """
    @spec trigger(module()) :: keyword()
    # sobelow_skip ["DOS.ModuleConcat"]
    def trigger(resource) do
      [
        name: :process,
        action: :process,
        where: Ash.Expr.expr(status == :pending),
        queue: :mishka_pay_inbox,
        max_attempts: 10,
        on_error: :fail,
        worker_module_name: Module.concat(resource, MishkaPayWorker),
        scheduler_module_name: Module.concat(resource, MishkaPayScheduler)
      ]
    end

    # Reads the provider object by its id and writes what the provider said, once per object. A
    # payment or a subscription with a user writes its owner there too (`MishkaPay.Ash.Owner`).
    defp sync(kind, id, change, user \\ nil) do
      {:sync, :create,
       upsert(kind,
         also: List.wrap(user),
         arguments: [
           argument(:provider, :string, allow_nil?: false),
           argument(id, :string, allow_nil?: false),
           argument(:tenant, :string)
         ],
         changes: [change(change)]
       )}
    end

    defp upsert(kind, opts) do
      {also, opts} = Keyword.pop(opts, :also, [])
      synced = for {name, _type, _opts} <- attributes(kind), name not in @object_keys, do: name
      {identity, _fields} = identity(kind)

      Keyword.merge(
        [
          accept: [],
          upsert?: true,
          upsert_identity: identity,
          upsert_fields: synced ++ also,
          upsert_condition: newer(kind)
        ],
        opts
      )
    end

    # A provider object is written over only by a read that is not older than the one kept.
    defp newer(:inbox), do: nil
    defp newer(_kind), do: Ash.Expr.expr(synced_at <= upsert_conflict(:synced_at))

    defp update(name, change, arguments, opts \\ []) do
      {name, :update,
       [require_atomic?: false, arguments: arguments, changes: [change(change)]] ++ opts}
    end

    defp subscription_update(name, opts, arguments),
      do:
        update(
          name,
          {MishkaPay.Ash.Subscription.Update, [operation: name] ++ announce(opts)},
          arguments
        )

    defp object(attributes) do
      [
        {:provider, :string, required()},
        {:provider_id, :string, required()},
        {:tenant, :string, public()}
      ] ++
        attributes ++
        [
          {:provider_created_at, :utc_datetime_usec, public()},
          {:synced_at, :utc_datetime_usec, required()}
        ]
    end

    defp money(name, field), do: {name, :term, {MishkaPay.Ash.Payment.Money, field: field}}

    defp announce(opts), do: [announce?: Keyword.get(opts, :announce?, true)]

    defp public(opts \\ []), do: [public?: true] ++ opts
    defp required(opts \\ []), do: [allow_nil?: false, public?: true] ++ opts

    defp argument(name, type, opts \\ []), do: Builder.build_action_argument(name, type, opts)

    defp change(change), do: Builder.build_action_change(change)
  end
end

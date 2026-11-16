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

    @type kind ::
            :inbox
            | :payment
            | :subscription
            | :customer
            | :dispute
            | :product
            | :price
            | :coupon
            | :promotion_code
            | :payment_link
            | :invoice
    @type attribute :: {atom(), atom(), keyword()}
    @type action :: {atom(), Ash.Resource.Actions.action_type(), keyword()}

    @kinds [
      :inbox,
      :payment,
      :subscription,
      :customer,
      :dispute,
      :product,
      :price,
      :coupon,
      :promotion_code,
      :payment_link,
      :invoice
    ]

    @objects MishkaPay.Ash.Object.Spec.kinds()

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
    def listener(kind) when kind in @objects, do: MishkaPay.Ash.Object.Listener

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

    def attributes(:product) do
      object([
        {:name, :string, public()},
        {:description, :string, public()},
        {:tax_code, :string, public()},
        {:active, :boolean, public()},
        {:default_price_id, :string, public()},
        {:metadata, :map, required(default: %{})},
        {:deleted_at, :utc_datetime_usec, public()}
      ])
    end

    def attributes(:price) do
      object([
        {:product_id, :string, public()},
        {:name, :string, public()},
        {:amount, :decimal, public()},
        {:currency, :string, public()},
        {:interval, :atom, public(constraints: [one_of: [:day, :week, :month, :year]])},
        {:interval_count, :integer, public()},
        {:tax_behavior, :atom, public(constraints: [one_of: [:inclusive, :exclusive]])},
        {:lookup_key, :string, public()},
        {:active, :boolean, public()},
        {:metadata, :map, required(default: %{})},
        {:deleted_at, :utc_datetime_usec, public()}
      ])
    end

    def attributes(:coupon) do
      object([
        {:name, :string, public()},
        {:percent_off, :decimal, public()},
        {:amount_off, :decimal, public()},
        {:currency, :string, public()},
        {:duration, :atom, public(constraints: [one_of: [:once, :repeating, :forever]])},
        {:duration_in_months, :integer, public()},
        {:max_redemptions, :integer, public()},
        {:redeem_by, :utc_datetime_usec, public()},
        {:valid, :boolean, public()},
        {:times_redeemed, :integer, public()},
        {:metadata, :map, required(default: %{})},
        {:deleted_at, :utc_datetime_usec, public()}
      ])
    end

    def attributes(:promotion_code) do
      object([
        {:code, :string, public()},
        {:coupon_id, :string, public()},
        {:active, :boolean, public()},
        {:max_redemptions, :integer, public()},
        {:times_redeemed, :integer, public()},
        {:expires_at, :utc_datetime_usec, public()},
        {:first_time_transaction, :boolean, public()},
        {:minimum_amount, :decimal, public()},
        {:currency, :string, public()},
        {:customer_id, :string, public()},
        {:metadata, :map, required(default: %{})},
        {:deleted_at, :utc_datetime_usec, public()}
      ])
    end

    def attributes(:payment_link) do
      object([
        {:url, :string, public()},
        {:active, :boolean, public()},
        {:price_ids, {:array, :string}, required(default: [])},
        {:max_purchases, :integer, public()},
        {:purchases, :integer, public()},
        {:metadata, :map, required(default: %{})},
        {:deleted_at, :utc_datetime_usec, public()}
      ])
    end

    def attributes(:invoice) do
      object([
        {:status, :atom,
         public(constraints: [one_of: [:draft, :open, :paid, :uncollectible, :void]])},
        {:number, :string, public()},
        {:customer_id, :string, public()},
        {:subscription_id, :string, public()},
        {:collection, :atom,
         public(constraints: [one_of: [:charge_automatically, :send_invoice]])},
        {:amount_due, :decimal, public()},
        {:amount_paid, :decimal, public()},
        {:total, :decimal, public()},
        {:currency, :string, public()},
        {:hosted_url, :string, public()},
        {:pdf_url, :string, public()},
        {:due_at, :utc_datetime_usec, public()},
        {:payment_id, :string, public()},
        {:reference, :string, public()},
        {:deleted_at, :utc_datetime_usec, public()}
      ])
    end

    @doc "The identity that keeps each provider object (or event) once."
    @spec identity(kind()) :: {atom(), [atom()]}
    def identity(:inbox), do: {:provider_event, [:provider, :event_id]}
    def identity(:payment), do: {:provider_payment, [:provider, :provider_id]}
    def identity(:subscription), do: {:provider_subscription, [:provider, :provider_id]}
    def identity(:customer), do: {:provider_customer, [:provider, :provider_id]}
    def identity(:dispute), do: {:provider_dispute, [:provider, :provider_id]}
    def identity(:product), do: {:provider_product, [:provider, :provider_id]}
    def identity(:price), do: {:provider_price, [:provider, :provider_id]}
    def identity(:coupon), do: {:provider_coupon, [:provider, :provider_id]}
    def identity(:promotion_code), do: {:provider_promotion_code, [:provider, :provider_id]}
    def identity(:payment_link), do: {:provider_payment_link, [:provider, :provider_id]}
    def identity(:invoice), do: {:provider_invoice, [:provider, :provider_id]}

    @doc """
    The calculations of a kind: its amounts as `Money`, and for a subscription `:active?` (gives
    access now, as `MishkaPay.Ash.Subscribed` counts it by default), `:on_trial?` and `:canceling?`
    (ends at the period's end), each usable in a filter or a sort.
    """
    @spec calculations(kind()) :: [{atom(), atom(), term()}]
    def calculations(:payment),
      do: [money(:money, :amount), money(:money_refunded, :amount_refunded)]

    def calculations(:subscription) do
      [
        money(:money, :amount),
        {:active?, :boolean,
         Ash.Expr.expr(
           status in [:active, :trialing] and
             (status != :trialing or is_nil(trial_end) or trial_end > now())
         )},
        {:on_trial?, :boolean,
         Ash.Expr.expr(status == :trialing and (is_nil(trial_end) or trial_end > now()))},
        {:canceling?, :boolean,
         Ash.Expr.expr(
           cancel_at_period_end == true and status not in [:canceled, :incomplete_expired]
         )}
      ]
    end

    def calculations(:dispute), do: [money(:money, :amount)]
    def calculations(:price), do: [money(:money, :amount)]
    def calculations(:coupon), do: [money(:money_off, :amount_off)]
    def calculations(:promotion_code), do: [money(:minimum, :minimum_amount)]

    def calculations(:invoice),
      do: [
        money(:money, :total),
        money(:money_due, :amount_due),
        money(:money_paid, :amount_paid)
      ]

    def calculations(_kind), do: []

    @doc """
    The actions of a kind, with `:resync` for every provider object's kind. `announce?: false`
    builds their changes without the
    `mishka_pay:<kind>:changed` event; `user:` names the `belongs_to_user` attribute, which a sync
    writes from the owner and a customer's `:register` accepts.
    """
    @spec actions(kind(), keyword()) :: [action()]
    def actions(:inbox, opts), do: kind_actions(:inbox, opts)

    # Every provider object's kind also re-reads one row from its provider: `:resync`, the
    # admin's refresh, and what the `resync_after` trigger runs.
    def actions(kind, opts) do
      actions = kind_actions(kind, opts)
      {:sync, :create, sync} = List.keyfind(actions, :sync, 0)

      actions ++
        [{:resync, :update, [require_atomic?: false, changes: Keyword.fetch!(sync, :changes)]}]
    end

    defp kind_actions(:inbox, _opts) do
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
        {:forget, :destroy, []},
        {:fail, :update,
         [
           require_atomic?: false,
           arguments: [argument(:error, :term)],
           changes: [change(MishkaPay.Ash.Inbox.Fail)]
         ]}
      ]
    end

    defp kind_actions(:payment, opts) do
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
        ]),
        read_action(:refunds, {:array, :struct}, [items: [instance_of: MishkaPay.Refund]], [])
      ]
    end

    defp kind_actions(:subscription, opts) do
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
        subscription_update(:change, opts, change_arguments()),
        subscription_update(:pause, opts, [
          argument(:behavior, :atom,
            constraints: [one_of: @pause_behaviors],
            default: :void,
            allow_nil?: false
          ),
          argument(:resumes_at, :utc_datetime)
        ]),
        subscription_update(:resume_collection, opts, []),
        read_action(:upcoming_invoice, :struct, [instance_of: MishkaPay.Invoice], []),
        read_action(
          :preview_change,
          :struct,
          [instance_of: MishkaPay.Invoice],
          change_arguments()
        )
      ]
    end

    defp kind_actions(:customer, opts) do
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

    defp kind_actions(:dispute, opts) do
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

    defp kind_actions(:product, opts) do
      object_actions(:product, opts,
        add: [
          argument(:name, :string, allow_nil?: false),
          argument(:description, :string),
          argument(:tax_code, :string),
          argument(:id, :string),
          argument(:metadata, :map)
        ],
        edit: [
          argument(:name, :string),
          argument(:description, :string),
          argument(:tax_code, :string),
          argument(:active, :boolean),
          argument(:metadata, :map)
        ],
        archive: []
      )
    end

    defp kind_actions(:price, opts) do
      object_actions(:price, opts,
        add: [
          argument(:product_id, :string, allow_nil?: false),
          argument(:amount, :map, allow_nil?: false),
          argument(:interval, :atom, constraints: [one_of: [:day, :week, :month, :year]]),
          argument(:interval_count, :integer, constraints: [min: 1]),
          argument(:tax_behavior, :atom, constraints: [one_of: [:inclusive, :exclusive]]),
          argument(:lookup_key, :string),
          argument(:metadata, :map)
        ],
        archive: []
      )
    end

    defp kind_actions(:coupon, opts) do
      object_actions(:coupon, opts,
        add: [
          argument(:id, :string),
          argument(:name, :string),
          argument(:percent_off, :decimal),
          argument(:amount_off, :map),
          argument(:duration, :atom, constraints: [one_of: [:once, :repeating, :forever]]),
          argument(:duration_in_months, :integer, constraints: [min: 1]),
          argument(:max_redemptions, :integer, constraints: [min: 1]),
          argument(:redeem_by, :utc_datetime),
          argument(:metadata, :map)
        ],
        remove: []
      )
    end

    defp kind_actions(:promotion_code, opts) do
      object_actions(:promotion_code, opts,
        add: [
          argument(:coupon_id, :string, allow_nil?: false),
          argument(:code, :string),
          argument(:max_redemptions, :integer, constraints: [min: 1]),
          argument(:expires_at, :utc_datetime),
          argument(:first_time_transaction, :boolean),
          argument(:minimum_amount, :map),
          argument(:customer_id, :string),
          argument(:metadata, :map)
        ],
        edit: [argument(:active, :boolean), argument(:metadata, :map)]
      )
    end

    defp kind_actions(:payment_link, opts) do
      object_actions(:payment_link, opts,
        add: [argument(:link, :map, allow_nil?: false)],
        edit: [argument(:changes, :map, allow_nil?: false)]
      )
    end

    defp kind_actions(:invoice, opts) do
      object_actions(:invoice, opts,
        add: [argument(:draft, :map, allow_nil?: false)],
        finalize: [],
        send: [],
        pay: [argument(:out_of_band, :boolean, default: false, allow_nil?: false)],
        void: [],
        mark_uncollectible: [],
        remove: []
      )
    end

    # The arguments of a plan or quantity change, and of its preview.
    defp change_arguments do
      [
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
      ]
    end

    # A read-only generic action on one row (`MishkaPay.Ash.RowRead`), by the row's `:id`.
    defp read_action(name, returns, constraints, arguments) do
      {name, :action,
       [
         returns: returns,
         constraints: constraints,
         arguments: [argument(:id, :uuid, allow_nil?: false) | arguments],
         run: {MishkaPay.Ash.RowRead, read: name}
       ]}
    end

    # A site-managed object kind (`MishkaPay.Ash.Object.Spec`): `:sync` from the provider, `:add`
    # at the provider (a create with the provider and tenant arguments), and each of its row
    # actions, all through `MishkaPay.Ash.Object.Change`.
    defp object_actions(kind, opts, actions) do
      change = &{MishkaPay.Ash.Object.Change, [kind: kind, operation: &1] ++ announce(opts)}
      sync = sync(kind, MishkaPay.Ash.Object.Spec.id_argument(kind), change.(:sync))

      made =
        for {name, arguments} <- actions do
          case name do
            :add ->
              {:add, :create,
               upsert(kind,
                 arguments:
                   [argument(:provider, :string, allow_nil?: false), argument(:tenant, :string)] ++
                     arguments,
                 changes: [change(change.(:add))]
               )}

            name ->
              update(name, change.(name), arguments)
          end
        end

      [sync | made]
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

    @doc """
    The hourly AshOban trigger that reads again, with `:resync`, the rows of `kind` still open at
    their provider and not read for `hours`; `nil` for a kind whose rows are never open.
    """
    @spec resync_trigger(module(), kind(), pos_integer()) :: keyword() | nil
    # sobelow_skip ["DOS.ModuleConcat"]
    def resync_trigger(resource, kind, hours) do
      case open(kind, hours) do
        nil ->
          nil

        where ->
          [
            name: :resync,
            action: :resync,
            where: where,
            queue: :mishka_pay_inbox,
            max_attempts: 3,
            scheduler_cron: "@hourly",
            worker_module_name: Module.concat(resource, MishkaPayResyncWorker),
            scheduler_module_name: Module.concat(resource, MishkaPayResyncScheduler)
          ]
      end
    end

    defp open(:payment, hours),
      do: Ash.Expr.expr(status in [:pending, :requires_action] and synced_at < ago(^hours, :hour))

    defp open(:subscription, hours),
      do:
        Ash.Expr.expr(
          status not in [:canceled, :incomplete_expired] and synced_at < ago(^hours, :hour)
        )

    defp open(:dispute, hours),
      do:
        Ash.Expr.expr(
          status in [
            :warning_needs_response,
            :warning_under_review,
            :needs_response,
            :under_review
          ] and
            synced_at < ago(^hours, :hour)
        )

    defp open(:invoice, hours),
      do: Ash.Expr.expr(status in [:draft, :open] and synced_at < ago(^hours, :hour))

    defp open(_kind, _hours), do: nil

    @doc """
    The inbox's daily AshOban trigger that deletes processed events older than `days`.
    """
    @spec forget_trigger(module(), pos_integer()) :: keyword()
    # sobelow_skip ["DOS.ModuleConcat"]
    def forget_trigger(resource, days) do
      [
        name: :forget,
        action: :forget,
        where: Ash.Expr.expr(status == :processed and processed_at < ago(^days, :day)),
        queue: :mishka_pay_inbox,
        max_attempts: 3,
        scheduler_cron: "@daily",
        worker_module_name: Module.concat(resource, MishkaPayForgetWorker),
        scheduler_module_name: Module.concat(resource, MishkaPayForgetScheduler)
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

    # A provider object's attributes are written only from the provider's word, by the kind's
    # changes; no action takes them as input, so a host's `accept :*` never reaches them.
    defp object(attributes) do
      ([
         {:provider, :string, required()},
         {:provider_id, :string, required()},
         {:tenant, :string, public()}
       ] ++
         attributes ++
         [
           {:provider_created_at, :utc_datetime_usec, public()},
           {:synced_at, :utc_datetime_usec, required()}
         ])
      |> Enum.map(fn {name, type, opts} -> {name, type, Keyword.put(opts, :writable?, false)} end)
    end

    defp money(name, field), do: {name, :term, {MishkaPay.Ash.Payment.Money, field: field}}

    defp announce(opts), do: [announce?: Keyword.get(opts, :announce?, true)]

    defp public(opts \\ []), do: [public?: true] ++ opts
    defp required(opts \\ []), do: [allow_nil?: false, public?: true] ++ opts

    defp argument(name, type, opts \\ []), do: Builder.build_action_argument(name, type, opts)

    defp change(change), do: Builder.build_action_change(change)
  end
end

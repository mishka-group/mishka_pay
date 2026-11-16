# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Customer do
    @moduledoc """
    Customers as an Ash resource fragment: a host keeps its own copy of each provider customer in a
    resource of its own domain, next to its users, and opens the provider's customer portal from it.

        defmodule MyApp.Pay.Customer do
          use Ash.Resource,
            domain: MyApp.Pay,
            data_layer: AshPostgres.DataLayer,
            fragments: [MishkaPay.Ash.Customer]

          postgres do
            table "pay_customers"
            repo MyApp.Repo
          end
        end

    and keeps it current from the webhook inbox (`MishkaPay.Ash.Inbox`) with
    `MishkaPay.Ash.Customer.Listener`:

        defmodule MyApp.Pay.CustomerSync do
          use MishkaPay.Ash.Customer.Listener, resource: MyApp.Pay.Customer
        end

    ## What it holds

    The provider and its customer id, the tenant, `:email`, `:name`, `:phone`, the caller's
    `:reference` (the host's own user id), `:metadata`, the `:default_payment_method`, when the
    provider made it, when it was last synced, and `:deleted_at` once the provider deleted it. An
    identity on provider and customer id keeps one row per customer.

    ## Actions

      * `:register` makes the customer at its provider (`MishkaPay.create_customer/1`) before its
        transaction starts and writes what the provider answered. It takes `:provider`, `:tenant`,
        `:email`, `:name`, `:phone`, `:reference` and `:metadata`. The same `:reference` and fields
        registered twice within a day are one customer and one row.
      * `:sync` takes `:provider`, `:customer_id` and `:tenant`, reads the customer
        (`MishkaPay.fetch_customer/3`) and writes what the provider said; the tenant is kept from
        the first time. A customer the provider deleted keeps its row, with `:deleted_at` set.
      * `:edit` changes `:email`, `:name`, `:phone` or `:metadata` at the provider
        (`MishkaPay.update_customer/1`) and writes its answer.
      * `:portal` takes the row's `:id` and a `:return_url` (and the provider's `:configuration`,
        when there is one) and answers a `MishkaPay.PortalSession`: redirect the buyer to its
        `:url`, where they manage their cards, invoices and subscriptions.

    After `:register`, `:sync` and `:edit`, `mishka_pay:customer:changed`
    (`MishkaPay.Events.customer_changed/0`) is fired with the customer and the row. Errors come back
    as Ash errors (`MishkaPay.Ash.to_ash_error/1`).
    """

    use Spark.Dsl.Fragment, of: Ash.Resource

    @synced [
      :email,
      :name,
      :phone,
      :reference,
      :metadata,
      :default_payment_method,
      :provider_created_at,
      :synced_at,
      :deleted_at
    ]

    attributes do
      uuid_v7_primary_key :id
      attribute :provider, :string, allow_nil?: false, public?: true
      attribute :provider_id, :string, allow_nil?: false, public?: true
      attribute :tenant, :string, public?: true
      attribute :email, :string, public?: true
      attribute :name, :string, public?: true
      attribute :phone, :string, public?: true
      attribute :reference, :string, public?: true
      attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true
      attribute :default_payment_method, :string, public?: true
      attribute :provider_created_at, :utc_datetime_usec, public?: true
      attribute :synced_at, :utc_datetime_usec, allow_nil?: false, public?: true
      attribute :deleted_at, :utc_datetime_usec, public?: true
      create_timestamp :inserted_at
      update_timestamp :updated_at
    end

    identities do
      identity :provider_customer, [:provider, :provider_id]
    end

    actions do
      defaults [:read]

      create :register do
        accept []
        argument :provider, :string, allow_nil?: false
        argument :tenant, :string
        argument :email, :string
        argument :name, :string
        argument :phone, :string
        argument :reference, :string
        argument :metadata, :map

        upsert? true
        upsert_identity :provider_customer
        upsert_fields @synced

        change {MishkaPay.Ash.Customer.Sync, operation: :register}
      end

      create :sync do
        accept []
        argument :provider, :string, allow_nil?: false
        argument :customer_id, :string, allow_nil?: false
        argument :tenant, :string

        upsert? true
        upsert_identity :provider_customer
        upsert_fields @synced

        change {MishkaPay.Ash.Customer.Sync, operation: :sync}
      end

      update :edit do
        require_atomic? false
        accept []
        argument :email, :string
        argument :name, :string
        argument :phone, :string
        argument :metadata, :map

        change {MishkaPay.Ash.Customer.Sync, operation: :edit}
      end

      action :portal, :struct do
        constraints instance_of: MishkaPay.PortalSession
        argument :id, :uuid, allow_nil?: false
        argument :return_url, :string, allow_nil?: false
        argument :configuration, :string
        run MishkaPay.Ash.Customer.Portal
      end
    end
  end
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Customer.Sync do
    @moduledoc """
    The `:register`, `:sync` and `:edit` actions of `MishkaPay.Ash.Customer`: asks the provider
    before the action's transaction starts, writes the customer as the provider answered it, and
    fires `mishka_pay:customer:changed` after. A customer the provider cannot give is an error on
    the action, and nothing is written; one the provider deleted keeps its row with `:deleted_at`.
    """

    use Ash.Resource.Change

    alias MishkaPay.{Customer, Errors, Events}
    alias MishkaPay.Helpers.Plugins

    @fields [:email, :name, :phone, :reference, :metadata]

    @impl true
    def change(changeset, opts, _context) do
      changeset
      |> Ash.Changeset.before_transaction(&ask(&1, opts[:operation]))
      |> Ash.Changeset.after_transaction(&announce/2)
    end

    defp ask(changeset, :register) do
      attrs =
        changeset
        |> arguments([:provider | @fields])
        |> Map.update(:metadata, nil, &stringify/1)
        |> Map.put(:tenant, MishkaPay.Ash.Tenant.of(changeset))

      changeset
      |> Ash.Changeset.force_change_attribute(:tenant, attrs[:tenant])
      |> write(MishkaPay.create_customer(attrs))
    end

    defp ask(changeset, :sync) do
      [provider, id] =
        Enum.map([:provider, :customer_id], &Ash.Changeset.get_argument(changeset, &1))

      tenant = MishkaPay.Ash.Tenant.of(changeset)

      changeset
      |> Ash.Changeset.force_change_attributes(%{
        provider: provider,
        provider_id: id,
        tenant: tenant
      })
      |> write(MishkaPay.fetch_customer(provider, id, tenant))
    end

    defp ask(%{data: row} = changeset, :edit) do
      attrs =
        changeset
        |> arguments(@fields -- [:reference])
        |> Map.update(:metadata, nil, &stringify/1)
        |> Map.merge(%{provider: row.provider, tenant: row.tenant, id: row.provider_id})

      write(changeset, MishkaPay.update_customer(attrs))
    end

    defp write(changeset, {:ok, %Customer{} = customer}) do
      changeset
      |> Ash.Changeset.force_change_attributes(attributes(customer))
      |> Ash.Changeset.put_context(:mishka_pay_customer, customer)
    end

    defp write(changeset, {:error, %Errors.Rejected{code: "customer_deleted"}}),
      do: Ash.Changeset.force_change_attributes(changeset, %{deleted_at: now(), synced_at: now()})

    defp write(changeset, {:error, error}),
      do: Ash.Changeset.add_error(changeset, MishkaPay.Ash.to_ash_error(error))

    # Only the arguments the caller set: an edit sends the provider just what changes.
    defp arguments(changeset, names) do
      for name <- names,
          Ash.Changeset.fetch_argument(changeset, name) != :error,
          into: %{},
          do: {name, Ash.Changeset.get_argument(changeset, name)}
    end

    defp stringify(nil), do: nil

    defp stringify(metadata),
      do: Map.new(metadata, fn {key, value} -> {to_string(key), value} end)

    defp attributes(customer) do
      %{
        provider: customer.provider,
        provider_id: customer.id,
        email: customer.email,
        name: customer.name,
        phone: customer.phone,
        reference: customer.reference,
        metadata: customer.metadata || %{},
        default_payment_method: customer.default_payment_method,
        provider_created_at: customer.created_at,
        synced_at: now(),
        deleted_at: nil
      }
    end

    defp now, do: DateTime.utc_now()

    # The answer of the listeners does not change the write: it already happened.
    defp announce(
           %{context: %{mishka_pay_customer: %Customer{} = customer}},
           {:ok, record} = result
         ) do
      timeout = Application.get_env(:mishka_pay, :customer_changed_timeout, 5_000)

      _answer =
        Plugins.call(Events.customer_changed(), %{customer: customer, record: record}, timeout)

      result
    end

    defp announce(_changeset, result), do: result
  end
end

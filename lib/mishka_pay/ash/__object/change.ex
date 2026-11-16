# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Object.Change do
    @moduledoc """
    The change of every action of a site-managed object kind (`MishkaPay.Ash.Object.Spec`):
    before the transaction it reads the object again (`:sync`), or makes or changes it at the
    provider (`:add`, `:edit`, `:archive`, an invoice's steps), and writes what the provider
    answered; after it, fires `mishka_pay:<kind>:changed` with `%{<kind> => struct, record:
    record}`. An object the provider deleted (a coupon, a draft bill) is kept with `deleted_at`.
    """

    use Ash.Resource.Change

    alias MishkaPay.Ash.Object.Spec
    alias MishkaPay.Helpers.Plugins

    @impl true
    def change(changeset, opts, _context) do
      kind = Keyword.fetch!(opts, :kind)

      MishkaPay.Ash.provider_change(
        changeset,
        opts,
        &ask(&1, kind, opts[:operation]),
        &announce(&1, &2, kind)
      )
    end

    defp ask(changeset, kind, :sync) do
      provider = Ash.Changeset.get_argument(changeset, :provider)
      id = Ash.Changeset.get_argument(changeset, Spec.id_argument(kind))
      tenant = MishkaPay.Ash.Tenant.of(changeset)

      changeset
      |> Ash.Changeset.force_change_attributes(%{
        provider: provider,
        provider_id: id,
        tenant: tenant
      })
      |> write(Spec.fetch(kind, provider, id, tenant), kind)
    end

    defp ask(changeset, kind, :add) do
      tenant = MishkaPay.Ash.Tenant.of(changeset)

      input =
        changeset
        |> arguments()
        |> Map.put(:tenant, tenant)

      changeset
      |> Ash.Changeset.force_change_attribute(:tenant, tenant)
      |> write(Spec.call(kind, :add, input), kind)
    end

    defp ask(%{data: row} = changeset, kind, operation) do
      input =
        changeset
        |> arguments()
        |> Map.merge(%{provider: row.provider, tenant: row.tenant, id: row.provider_id})

      case Spec.call(kind, operation, input) do
        :ok -> Ash.Changeset.force_change_attribute(changeset, :deleted_at, DateTime.utc_now())
        answer -> write(changeset, answer, kind)
      end
    end

    defp write(changeset, {:ok, object}, kind) do
      changeset
      |> Ash.Changeset.force_change_attributes(Spec.attributes(object))
      |> Ash.Changeset.put_context(:mishka_pay_object, {kind, object})
    end

    defp write(changeset, {:error, error}, _kind),
      do: Ash.Changeset.add_error(changeset, MishkaPay.Ash.to_ash_error(error))

    # Only the arguments the caller set, so a change sends the provider just what changes.
    defp arguments(changeset) do
      for %{name: name} <- changeset.action.arguments,
          name not in [:tenant],
          Ash.Changeset.fetch_argument(changeset, name) != :error,
          into: %{},
          do: {name, Ash.Changeset.get_argument(changeset, name)}
    end

    defp announce(%{context: %{mishka_pay_object: {kind, object}}}, {:ok, record} = result, kind) do
      timeout = Application.get_env(:mishka_pay, :object_changed_timeout, 5_000)

      _answer =
        Plugins.call(MishkaPay.Events.changed(kind), %{kind => object, record: record}, timeout)

      result
    end

    defp announce(_changeset, result, _kind), do: result
  end
end

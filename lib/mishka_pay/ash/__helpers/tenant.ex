# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Tenant do
    @moduledoc """
    How the Ash layer finds the tenant a provider call is for (`MishkaPay.Credentials`), so it
    works the same in a single-site project and in a multi-tenant one like Mishka CMS.

    A Mishka Pay resource may carry Ash multitenancy on the host's own attribute:

        multitenancy do
          strategy :attribute
          attribute :site_id
        end

    Its actions then run with the site as Ash's tenant (`tenant: site.id`), and that tenant is the
    one the provider's keys are read for; the listeners sync each webhook's row inside the
    webhook's own tenant (`/pay/webhooks/stripe/<site id>`). Without multitenancy the `:tenant`
    argument says it. The row keeps it in its `:tenant` attribute either way, so later actions
    (refund, cancel, edit) use the same keys. The webhook inbox stays global: a webhook arrives
    before any tenant is chosen.
    """

    @doc """
    The tenant of an action: a create's `:tenant` argument, else Ash's tenant; a generic action's
    (`:start_checkout`) is Ash's tenant.
    """
    @spec of(Ash.Changeset.t() | Ash.ActionInput.t()) :: String.t() | nil
    def of(%Ash.ActionInput{tenant: tenant}), do: text(tenant)

    def of(changeset) do
      case Ash.Changeset.get_argument(changeset, :tenant) do
        nil -> text(changeset.tenant)
        tenant -> text(tenant)
      end
    end

    @doc """
    `attrs` (a call's map) with `tenant` when they name none, so an action run in a site's Ash tenant
    calls the provider with that site's keys.
    """
    @spec into(map(), String.t() | nil) :: map()
    def into(attrs, nil), do: attrs

    def into(attrs, tenant) when is_map(attrs) do
      case Map.has_key?(attrs, :tenant) or Map.has_key?(attrs, "tenant") do
        true -> attrs
        false -> Map.put(attrs, :tenant, tenant)
      end
    end

    @doc "The Ash options a listener syncs `resource` with, for an event of `tenant`."
    @spec opts(module(), term()) :: keyword()
    def opts(resource, tenant) do
      case Ash.Resource.Info.multitenancy_strategy(resource) do
        nil -> [authorize?: false]
        _strategy -> [authorize?: false, tenant: tenant]
      end
    end

    defmodule Into do
      @moduledoc """
      Writes a create action's tenant (`MishkaPay.Ash.Tenant.of/1`) into the host's own attribute,
      the `tenant_from` of `MishkaPay.Ash.Resource`, unless the action sets it itself.
      """

      use Ash.Resource.Change

      @impl true
      def change(changeset, opts, _context) do
        attribute = Keyword.fetch!(opts, :attribute)

        case {Ash.Changeset.changing_attribute?(changeset, attribute),
              MishkaPay.Ash.Tenant.of(changeset)} do
          {false, tenant} when is_binary(tenant) ->
            Ash.Changeset.force_change_attribute(changeset, attribute, tenant)

          _set_or_none ->
            changeset
        end
      end
    end

    defp text(nil), do: nil
    defp text(tenant) when is_binary(tenant), do: tenant
    defp text(tenant), do: to_string(Ash.ToTenant.to_tenant(tenant, nil))
  end
end

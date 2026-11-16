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

    @doc "The tenant of a create action: its `:tenant` argument, else Ash's tenant."
    @spec of(Ash.Changeset.t()) :: String.t() | nil
    def of(changeset) do
      case Ash.Changeset.get_argument(changeset, :tenant) do
        nil -> text(changeset.tenant)
        tenant -> text(tenant)
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

    defp text(nil), do: nil
    defp text(tenant) when is_binary(tenant), do: tenant
    defp text(tenant), do: to_string(Ash.ToTenant.to_tenant(tenant, nil))
  end
end

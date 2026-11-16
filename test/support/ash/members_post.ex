# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.MembersPost do
  @moduledoc """
  A host's members-only post, as a blog keeps one: read only by a member with a subscription,
  and its pro reading only with the pro product (`MishkaPay.Ash.Subscribed`).
  """

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  ets do
    private? true
  end

  actions do
    defaults [:read, create: [:title]]
    read :pro
  end

  policies do
    policy action(:create) do
      authorize_if always()
    end

    policy action(:read) do
      authorize_if {MishkaPay.Ash.Subscribed, resource: MishkaPay.Support.SiteSubscription}
    end

    policy action(:pro) do
      authorize_if {MishkaPay.Ash.Subscribed,
                    resource: MishkaPay.Support.SiteSubscription, product: "prod_pro"}
    end
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, public?: true
  end
end

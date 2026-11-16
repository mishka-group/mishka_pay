# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.SiteSubscription do
  @moduledoc """
  A multi-tenant host's subscriptions, as Mishka CMS keeps them: Ash multitenancy on the host's
  own `:site_id`, each row of a member (`belongs_to_user`).
  """

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  postgres do
    table "site_subscriptions"
    repo MishkaPay.Support.Repo
  end

  mishka_pay do
    kind :subscription
    belongs_to_user MishkaPay.Support.Member
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
  end

  attributes do
    attribute :site_id, :string, allow_nil?: false, public?: true
  end
end

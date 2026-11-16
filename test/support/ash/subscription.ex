# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Subscription do
  @moduledoc "A host's subscription resource, as `MishkaPay.Ash.Resource` shows its `:subscription` kind."

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  postgres do
    table "pay_subscriptions"
    repo MishkaPay.Support.Repo
  end

  mishka_pay do
    kind :subscription
    resync_after 6
  end
end

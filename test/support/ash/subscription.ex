# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Subscription do
  @moduledoc "A host's subscription resource, as `MishkaPay.Ash.Subscription` shows it."

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [MishkaPay.Ash.Subscription]

  postgres do
    table "pay_subscriptions"
    repo MishkaPay.Support.Repo
  end
end

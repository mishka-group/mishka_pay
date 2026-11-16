# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Member do
  @moduledoc "A host's user, who pays for a membership (`belongs_to_user` of `MishkaPay.Ash.Resource`)."

  use Ash.Resource, domain: MishkaPay.Support.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table "members"
    repo MishkaPay.Support.Repo
  end

  actions do
    defaults [:read, :create]
  end

  attributes do
    uuid_v7_primary_key :id
  end
end

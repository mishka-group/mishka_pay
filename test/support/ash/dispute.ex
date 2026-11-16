# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Dispute do
  @moduledoc "A host's dispute resource, as `MishkaPay.Ash.Dispute` shows it."

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [MishkaPay.Ash.Dispute]

  postgres do
    table "pay_disputes"
    repo MishkaPay.Support.Repo
  end
end

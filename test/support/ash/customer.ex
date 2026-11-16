# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Customer do
  @moduledoc "A host's customer resource, as `MishkaPay.Ash.Customer` shows it."

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [MishkaPay.Ash.Customer]

  postgres do
    table "pay_customers"
    repo MishkaPay.Support.Repo
  end
end

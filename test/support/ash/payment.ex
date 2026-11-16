# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Payment do
  @moduledoc "A host's payment resource, as `MishkaPay.Ash.Resource` shows its `:payment` kind."

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  postgres do
    table "pay_payments"
    repo MishkaPay.Support.Repo
  end

  mishka_pay do
    kind :payment
  end
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Balance do
  @moduledoc """
  The money a provider holds for the seller, read with `MishkaPay.fetch_balance/2`. A
  guarded_struct the provider fills in.

    * `:provider`: whose balance.
    * `:available`: one `Money` per currency, ready to pay out.
    * `:pending`: one `Money` per currency, not available yet.

  A balance may be below zero, such as after refunds or disputes larger than new sales.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "validate(string)"
    field :available, [Money.t()], default: [], derives: "validate(list)"
    field :pending, [Money.t()], default: [], derives: "validate(list)"
  end
end

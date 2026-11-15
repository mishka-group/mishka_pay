# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Ash do
  @moduledoc """
  The Ash layer, for projects that use Ash. Without Ash none of it compiles and the rest of Mishka
  Pay works on plain structs.

  `MishkaPay.Ash` is a Spark extension (`pay do ... end`). It turns a resource of the host's own
  domain into a customer, price, payment or subscription, with actions such as `start_checkout`,
  `refund` and `sync_from_provider`, built on the core calls:

      use Ash.Resource, extensions: [MishkaPay.Ash]

  The webhook inbox is its own extension, `MishkaPay.Ash.Inbox`.

  `MishkaPay.Errors` errors become Ash errors by class here: `:invalid` an `Ash.Error.Invalid`,
  everything else an `Ash.Error.Unknown`.

  Stage 4 adds it.
  """
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Ash do
  @moduledoc """
  The Ash layer, for projects that use Ash. Without Ash none of it compiles and the
  rest of Mishka Pay works on plain structs.

  It adds:

    * `MishkaPay.Ash.Resource`: a Spark extension that turns a resource of the host's own domain into a
      customer, price, payment or subscription, with actions such as `start_checkout`, `refund` and
      `sync_from_provider`, built on the core calls.
    * `MishkaPay.Ash.Inbox`: a Spark extension for the webhook inbox. A plugin on
      `mishka_pay:webhook:received` stores each event once and an AshOban trigger works it with
      retries.

  Stage 4 adds it.
  """
end

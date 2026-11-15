# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Events do
  @moduledoc """
  Every mishka_installer event Mishka Pay fires, in one place. Code and `use` macros call
  these functions and never write an event name by hand.

  | Event | Who listens | What it is for |
  |---|---|---|
  | `mishka_pay:providers` | each provider | says which providers are installed |
  | `mishka_pay:credentials` | the host | gives the keys of a provider for one site |
  | `mishka_pay:checkout:before` | the host | changes or refuses a checkout before the provider sees it |
  | `mishka_pay:webhook:received` | the Ash inbox, or the host | a provider event whose signature was checked |
  | `mishka_pay:payment:changed` | the host | a payment's state after it was synced from the provider |

  Stage 1 adds the functions.
  """
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Events do
  @moduledoc """
  Every mishka_installer event Mishka Pay fires, in one place. Code and `use` macros call these
  functions and never write an event name by hand.

  | Event | Who listens | What it is for |
  |---|---|---|
  | `mishka_pay:providers` | each provider | says which providers are installed |
  | `mishka_pay:credentials` | the host | gives the keys of a provider for one site |
  | `mishka_pay:checkout:before` | the host | changes or refuses a checkout before the provider sees it |
  | `mishka_pay:webhook:received` | the Ash inbox, or the host | a provider event whose signature was checked |
  | `mishka_pay:payment:changed` | the host | a payment's state after it was synced from the provider |

  The webhook and payment events arrive with the stage that fires them.
  """

  @doc "Every provider listens here and adds itself to the `providers` list the event carries."
  @spec providers() :: String.t()
  def providers, do: "mishka_pay:providers"

  @doc "The host listens here and answers a provider's keys for one site."
  @spec credentials() :: String.t()
  def credentials, do: "mishka_pay:credentials"

  @doc """
  Hosts listen here to change or refuse a checkout before the provider sees it. A plugin gets
  `%{checkout: %MishkaPay.Checkout{}, refused: nil}` and answers it with a changed `:checkout`, or
  with `:refused` set to a reason. See `MishkaPay.checkout/1`.
  """
  @spec checkout_before() :: String.t()
  def checkout_before, do: "mishka_pay:checkout:before"
end

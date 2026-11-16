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
  | `mishka_pay:event:process` | the host, or a payment resource | works one event the Ash inbox stored |
  | `mishka_pay:payment:changed` | the host | a payment's state after it was synced from the provider |
  | `mishka_pay:subscription:changed` | the host | a subscription's state after it was synced, cancelled or resumed |
  | `mishka_pay:customer:changed` | the host | a customer after it was registered, synced or edited |
  | `mishka_pay:dispute:changed` | the host | a dispute after it was synced, answered or accepted |

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

  @doc """
  Listeners get every provider event whose signature was checked, as `%{event:
  %MishkaPay.Event{}, failed: nil}`, and answer it with `:failed` set to a reason when they could
  not take it, so the provider sends it again. See `MishkaPay.Webhook`.
  """
  @spec webhook_received() :: String.t()
  def webhook_received, do: "mishka_pay:webhook:received"

  @doc """
  The inbox (the `:inbox` kind of `MishkaPay.Ash.Resource`) fires this to work one stored event,
  once per try. Listeners get `%{event: %MishkaPay.Event{}, failed: nil}` and answer it with
  `:failed` set to a reason when the work did not finish, so the inbox tries again later.
  """
  @spec event_process() :: String.t()
  def event_process, do: "mishka_pay:event:process"

  @doc """
  Fired after a payment resource (the `:payment` kind of `MishkaPay.Ash.Resource`) synced a
  payment from its provider, with `%{payment: %MishkaPay.Payment{}, record: record}`. A host
  listens here to act on a paid or refunded payment, or to push the change to the screens that
  show it.
  """
  @spec payment_changed() :: String.t()
  def payment_changed, do: "mishka_pay:payment:changed"

  @doc """
  Fired after a subscription resource (the `:subscription` kind of `MishkaPay.Ash.Resource`)
  synced, cancelled or resumed a subscription, with `%{subscription: %MishkaPay.Subscription{},
  record: record}`. A host listens here to give or take access, or to push the change to the
  screens that show it.
  """
  @spec subscription_changed() :: String.t()
  def subscription_changed, do: "mishka_pay:subscription:changed"

  @doc """
  Fired after a customer resource (the `:customer` kind of `MishkaPay.Ash.Resource`) registered,
  synced or edited a customer, with `%{customer: %MishkaPay.Customer{}, record: record}`. A host
  listens here to link the customer to its user, or to push the change to the screens that show
  it.
  """
  @spec customer_changed() :: String.t()
  def customer_changed, do: "mishka_pay:customer:changed"

  @doc """
  Fired after a dispute resource (the `:dispute` kind of `MishkaPay.Ash.Resource`) synced,
  answered or accepted a dispute, with `%{dispute: %MishkaPay.Dispute{}, record: record}`. A host
  listens here to take back what the payment gave while it is open, and give it again when it is
  won.
  """
  @spec dispute_changed() :: String.t()
  def dispute_changed, do: "mishka_pay:dispute:changed"
end

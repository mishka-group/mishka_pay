defmodule Shop.Pay.FailingListener do
  @moduledoc """
  A host listener on `mishka_pay:webhook:received` that cannot take one kind of event, so the
  webhook simulator can show what happens then: the endpoint answers 500 and Stripe would send the
  event again later. Every other event it leaves alone.
  """

  use MishkaInstaller.Event.Hook, event: "mishka_pay:webhook:received"

  @type_name "mishka.demo.listener_fails"

  @doc "The event type it fails on."
  def type, do: @type_name

  @impl true
  def call(%{event: %{type: @type_name}} = state),
    do: {:reply, %{state | failed: "the demo's failing listener does not take this event"}}

  def call(state), do: {:reply, state}
end

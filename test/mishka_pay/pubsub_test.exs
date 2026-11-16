# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.PubSubTest do
  # Starts plugins on Mishka Pay's events, which every test sees.
  use ExUnit.Case, async: false

  alias MishkaPay.{Events, Payment}
  alias MishkaPay.Helpers.Plugins
  alias MishkaPay.Support.Broadcast

  doctest MishkaPay.PubSub

  setup do
    start_supervised!({Phoenix.PubSub, name: MishkaPay.Support.PubSub})
    Enum.each(Broadcast.plugins(), &MishkaPay.Test.start_plugin!/1)
    :ok
  end

  test "a change is broadcast on its kind's topic and on its tenant's" do
    Phoenix.PubSub.subscribe(MishkaPay.Support.PubSub, MishkaPay.PubSub.topic(:payment))
    Phoenix.PubSub.subscribe(MishkaPay.Support.PubSub, MishkaPay.PubSub.topic(:payment, "site-a"))
    Phoenix.PubSub.subscribe(MishkaPay.Support.PubSub, MishkaPay.PubSub.topic(:payment, "site-b"))

    payment = struct(Payment, provider: "stripe", id: "pi_1")

    Plugins.call(
      Events.payment_changed(),
      %{payment: payment, record: %{tenant: "site-a"}},
      5_000
    )

    assert_receive {:mishka_pay, :payment,
                    %{payment: %Payment{id: "pi_1"}, record: %{tenant: "site-a"}}}

    assert_receive {:mishka_pay, :payment, %{payment: %Payment{id: "pi_1"}}}
    refute_receive {:mishka_pay, :payment, _site_b}, 50
  end

  test "every kind has its plugin, and a change without a tenant goes to the kind's topic only" do
    assert length(Broadcast.plugins()) == length(MishkaPay.PubSub.kinds())

    for kind <- MishkaPay.PubSub.kinds() do
      Phoenix.PubSub.subscribe(MishkaPay.Support.PubSub, MishkaPay.PubSub.topic(kind))
      Plugins.call(MishkaPay.PubSub.event(kind), %{kind => %{id: "x"}, record: nil}, 5_000)
      assert_receive {:mishka_pay, ^kind, %{record: nil}}
    end
  end

  test "an unknown kind is refused when the module compiles" do
    assert_raise ArgumentError, ~r/kinds are/, fn ->
      Code.compile_quoted(
        quote do
          defmodule MishkaPay.Support.BadBroadcast do
            use MishkaPay.PubSub, pubsub: Nope, kinds: [:refund]
          end
        end
      )
    end
  end
end

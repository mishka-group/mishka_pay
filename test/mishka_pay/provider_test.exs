# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.ProviderTest do
  # The providers event is compiled once for the whole node.
  use ExUnit.Case, async: false

  alias MishkaInstaller.Event.Event
  alias MishkaPay.{Errors, Provider}
  alias MishkaPay.Support.{Acme, AcmeTwin, Hidden}

  test "an installed provider is found by its id, with what `use` declared" do
    MishkaPay.Test.start_plugin!(Acme)

    assert {:ok, Acme} = Provider.fetch("acme")
    assert Acme in Provider.all()
    assert Acme.label() == "Acme Pay"
    assert Acme.capabilities() == [:checkout, :refund, :subscription, :customer, :portal]
  end

  test "an id nobody installed is an unknown provider, in the invalid class" do
    assert {:error, %Errors.UnknownProvider{provider: "nope", reason: :not_installed} = error} =
             Provider.fetch("nope")

    assert %Errors.Invalid{} = Errors.to_class(error)
  end

  test "when two providers share an id, the one first on the event wins" do
    MishkaPay.Test.start_plugin!(AcmeTwin)
    MishkaPay.Test.start_plugin!(Acme)

    assert {:ok, Acme} = Provider.fetch("acme")
    refute AcmeTwin in Provider.all()
  end

  test "a provider whose offered?/0 says no is installed but not offered" do
    MishkaPay.Test.start_plugin!(Hidden)

    assert Hidden in Provider.all()
    refute Hidden in Provider.offered()
    assert {:error, %Errors.UnknownProvider{reason: :not_installed}} = Provider.fetch("hidden")
  end

  @tag :capture_log
  test "a provider whose offered?/0 raises is left out, and the others still work" do
    MishkaPay.Test.start_plugin!(MishkaPay.Support.Broken)
    MishkaPay.Test.start_plugin!(Acme)

    refute MishkaPay.Support.Broken in Provider.offered()
    assert {:ok, Acme} = Provider.fetch("acme")
  end

  test "stopping a provider's plugin takes it out" do
    MishkaPay.Test.start_plugin!(Acme)
    {:ok, _stopped} = Event.stop(:name, Acme, false)

    refute Acme in Provider.all()
    assert {:error, %Errors.UnknownProvider{}} = Provider.fetch("acme")
  end

  test "use refuses what it cannot check, when the module compiles" do
    for {opts, message} <- [
          {[id: "Bad Id", label: "Bad"], ~r/lowercase/},
          {[id: "abc\n", label: "Bad"], ~r/lowercase/},
          {[id: :bad, label: "Bad"], ~r/literal string/},
          {[id: "bad", label: 123], ~r/label/},
          {[id: "bad", label: "Bad", capabilities: [:teleport]],
           ~r/unknown provider capabilities: \[:teleport\]/},
          {[id: "bad", label: "Bad", capabilities: [:refund, :refund]],
           ~r/listed twice: \[:refund\]/},
          {[id: "bad", label: "Bad", priority: -5], ~r/priority/},
          {[id: "bad", label: "Bad", bogus: 1],
           ~r/unknown MishkaPay.Provider options: \[:bogus\]/}
        ] do
      assert_raise ArgumentError, message, fn ->
        Code.compile_quoted(
          quote do
            defmodule MishkaPay.Support.Refused do
              use MishkaPay.Provider, unquote(opts)
            end
          end
        )
      end
    end
  end
end

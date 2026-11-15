# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.ProviderTest do
  # The providers event is compiled once for the whole node.
  use ExUnit.Case, async: false

  alias MishkaInstaller.Event.Event
  alias MishkaPay.{Errors, Provider}
  alias MishkaPay.Test.{Acme, AcmeTwin, Hidden, Installer}

  test "an installed provider is found by its id, with what `use` declared" do
    Installer.start!(Acme)

    assert {:ok, Acme} = Provider.fetch("acme")
    assert Acme in Provider.all()
    assert Acme.label() == "Acme Pay"
    assert Acme.capabilities() == [:checkout, :refund]
  end

  test "an id nobody installed is an unknown provider, in the invalid class" do
    assert {:error, %Errors.UnknownProvider{provider: "nope", reason: :not_installed} = error} =
             Provider.fetch("nope")

    assert %Errors.Invalid{} = Errors.to_class(error)
  end

  test "when two providers share an id, the one first on the event wins" do
    Installer.start!(AcmeTwin)
    Installer.start!(Acme)

    assert {:ok, Acme} = Provider.fetch("acme")
    refute AcmeTwin in Provider.all()
  end

  test "a provider whose offered?/0 says no is installed but not offered" do
    Installer.start!(Hidden)

    assert Hidden in Provider.all()
    refute Hidden in Provider.offered()
    assert {:error, %Errors.UnknownProvider{reason: :not_installed}} = Provider.fetch("hidden")
  end

  test "stopping a provider's plugin takes it out" do
    Installer.start!(Acme)
    {:ok, _stopped} = Event.stop(:name, Acme, false)

    refute Acme in Provider.all()
    assert {:error, %Errors.UnknownProvider{}} = Provider.fetch("acme")
  end

  test "use refuses an id or a capability it does not know, when the module compiles" do
    assert_raise ArgumentError, ~r/lowercase/, fn ->
      Code.compile_quoted(
        quote do
          defmodule MishkaPay.Test.BadId do
            use MishkaPay.Provider, id: "Bad Id", label: "Bad"
          end
        end
      )
    end

    assert_raise ArgumentError, ~r/unknown provider capabilities: \[:teleport\]/, fn ->
      Code.compile_quoted(
        quote do
          defmodule MishkaPay.Test.BadCapability do
            use MishkaPay.Provider, id: "bad", label: "Bad", capabilities: [:teleport]
          end
        end
      )
    end
  end
end

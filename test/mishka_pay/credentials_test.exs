# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.CredentialsTest do
  # The credentials event is compiled once for the whole node.
  use ExUnit.Case, async: false

  alias GuardedStruct.Errors.Validation
  alias MishkaPay.{Credentials, Errors}
  alias MishkaPay.Test.{FallbackKeys, Installer, SiteKeys}

  test "with no plugin answering, the keys are missing" do
    assert {:error, %Errors.MissingCredentials{provider: "acme", tenant: "site-a"} = error} =
             Credentials.fetch("acme", "site-a")

    assert error.reason == :no_answer
  end

  test "a host plugin answers one tenant's keys, checked as the struct" do
    Installer.start!(SiteKeys)

    assert {:ok, %Credentials{} = keys} = Credentials.fetch("acme", "site-a")
    assert keys.provider == "acme"
    assert keys.tenant == "site-a"
    assert keys.mode == :test
    assert keys.secret_key == "sk_test_site_a"
    assert keys.extra == %{"account" => "acct_1"}

    assert {:error, %Errors.MissingCredentials{reason: :no_answer}} =
             Credentials.fetch("acme", "site-b")
  end

  test "inspect never shows a key" do
    Installer.start!(SiteKeys)
    {:ok, keys} = Credentials.fetch("acme", "site-a")

    refute inspect(keys) =~ "sk_test"
    refute inspect(keys) =~ "whsec"
    assert inspect(keys) =~ "site-a"
  end

  test "the first plugin that answers wins" do
    Installer.start!(FallbackKeys)
    Installer.start!(SiteKeys)

    assert {:ok, %{secret_key: "sk_test_site_a"}} = Credentials.fetch("acme", "site-a")
    assert {:ok, %{secret_key: "sk_test_fallback"}} = Credentials.fetch("acme", "site-z")
  end

  test "an answer that is not valid keys is refused on its field" do
    Installer.start!(SiteKeys)

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :mode}]}} =
             Credentials.fetch("acme", "site-unknown-mode")

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :token}]}} =
             Credentials.fetch("acme", "site-extra-key")
  end

  test "an answer that is not a map is refused, never a crash" do
    Installer.start!(SiteKeys)

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :credentials}]}} =
             Credentials.fetch("acme", "site-not-a-map")
  end

  test "an answer read from JSON works, and cannot change the provider it is for" do
    Installer.start!(SiteKeys)

    assert {:ok, keys} = Credentials.fetch("acme", "site-from-json")
    assert keys.provider == "acme"
    assert keys.mode == :live
    assert keys.secret_key == "sk_live_json"
    assert keys.extra == %{}
  end

  @tag :capture_log
  test "a plugin that raises leaves the keys missing, never half read" do
    Installer.start!(SiteKeys)

    assert {:error, %Errors.MissingCredentials{reason: :raised}} =
             Credentials.fetch("acme", "site-boom")
  end
end

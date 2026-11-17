# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.CredentialsTest do
  # The credentials event is compiled once for the whole node.
  use ExUnit.Case, async: false

  alias GuardedStruct.Errors.Validation
  alias MishkaPay.{Credentials, Errors}
  alias MishkaPay.Support.{FallbackKeys, SiteKeys}

  test "with no plugin answering, the keys are missing" do
    assert {:error, %Errors.MissingCredentials{provider: "acme", tenant: "site-a"} = error} =
             Credentials.fetch("acme", "site-a")

    assert error.reason == :no_answer
  end

  test "a host plugin answers one tenant's keys, checked as the struct" do
    MishkaPay.Test.start_plugin!(SiteKeys)

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
    MishkaPay.Test.start_plugin!(SiteKeys)
    {:ok, keys} = Credentials.fetch("acme", "site-a")

    refute inspect(keys) =~ "sk_test"
    refute inspect(keys) =~ "whsec"
    assert inspect(keys) =~ "site-a"
  end

  test "the first plugin that answers wins" do
    MishkaPay.Test.start_plugin!(FallbackKeys)
    MishkaPay.Test.start_plugin!(SiteKeys)

    assert {:ok, %{secret_key: "sk_test_site_a"}} = Credentials.fetch("acme", "site-a")
    assert {:ok, %{secret_key: "sk_test_fallback"}} = Credentials.fetch("acme", "site-z")
  end

  test "an answer that is not valid keys is refused on its field" do
    MishkaPay.Test.start_plugin!(SiteKeys)

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :mode}]}} =
             Credentials.fetch("acme", "site-unknown-mode")

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :token}]}} =
             Credentials.fetch("acme", "site-extra-key")
  end

  test "an answer that is not a map is refused, never a crash" do
    MishkaPay.Test.start_plugin!(SiteKeys)

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :credentials}]}} =
             Credentials.fetch("acme", "site-not-a-map")
  end

  test "an answer read from JSON works, and cannot change the provider it is for" do
    MishkaPay.Test.start_plugin!(SiteKeys)

    assert {:ok, keys} = Credentials.fetch("acme", "site-from-json")
    assert keys.provider == "acme"
    assert keys.mode == :live
    assert keys.secret_key == "sk_live_json"
    assert keys.extra == %{}
  end

  test "a tenant's refund rule is read at runtime: once by default, many when its settings say so" do
    MishkaPay.Test.put_keys("acme", %{secret_key: "sk_test_a"})
    assert {:ok, %{refunds: :once}} = Credentials.fetch("acme", "site-a")

    MishkaPay.Test.put_keys("acme", %{secret_key: "sk_test_a", refunds: "many"})
    assert {:ok, %{refunds: :many}} = Credentials.fetch("acme", "site-a")

    MishkaPay.Test.put_keys("acme", %{secret_key: "sk_test_a", refunds: "sometimes"})

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :refunds}]}} =
             Credentials.fetch("acme", "site-a")
  end

  test "older webhook secrets are kept beside the current one, checked and never shown" do
    MishkaPay.Test.put_keys("acme", %{secret_key: "sk_test_a"})
    assert {:ok, %{webhook_secrets: []} = keys} = Credentials.fetch("acme", "site-a")
    assert Credentials.webhook_secrets(keys) == []

    MishkaPay.Test.put_keys("acme", %{
      secret_key: "sk_test_a",
      webhook_secret: "whsec_new",
      webhook_secrets: [" whsec_old ", "whsec_new"]
    })

    assert {:ok, keys} = Credentials.fetch("acme", "site-a")
    assert Credentials.webhook_secrets(keys) == ["whsec_new", "whsec_old"]
    refute inspect(keys) =~ "whsec"

    MishkaPay.Test.put_keys("acme", %{secret_key: "sk_test_a", webhook_secrets: ["whsec_old"]})
    assert {:ok, keys} = Credentials.fetch("acme", "site-a")
    assert Credentials.webhook_secrets(keys) == ["whsec_old"]

    for bad <- [["whsec_old", ""], ["whsec_old", 42], "whsec_old"] do
      MishkaPay.Test.put_keys("acme", %{secret_key: "sk_test_a", webhook_secrets: bad})

      assert {:error, %Errors.Invalid{errors: [%Validation{field: :webhook_secrets}]}} =
               Credentials.fetch("acme", "site-a")
    end
  end

  defp watch_fetches,
    do: :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :credentials, :stop]])

  @tag :capture_log
  test "a plugin that exits or throws is a missing-keys error, and the caller lives on" do
    MishkaPay.Test.start_plugin!(SiteKeys)
    ref = watch_fetches()

    for tenant <- ["site-exit", "site-throw"] do
      assert {:error, %Errors.MissingCredentials{reason: :exited}} =
               Credentials.fetch("acme", tenant)

      assert_received {[:mishka_pay, :credentials, :stop], ^ref, _,
                       %{tenant: ^tenant, outcome: :exited}}
    end
  end

  # No time passes here: with a limit of 0 the hanging plugin cannot answer, and the stop event
  # says why the fetch ended.
  test "a plugin that never answers is stopped at the time limit" do
    MishkaPay.Test.start_plugin!(SiteKeys)
    ref = watch_fetches()

    assert {:error, %Errors.MissingCredentials{reason: :timeout}} =
             Credentials.fetch("acme", "site-hang", timeout: 0)

    assert_received {[:mishka_pay, :credentials, :stop], ^ref, _,
                     %{tenant: "site-hang", outcome: :timeout}}
  end

  test "every fetch tells its outcome, never a key" do
    MishkaPay.Test.start_plugin!(SiteKeys)
    ref = watch_fetches()

    assert {:ok, _keys} = Credentials.fetch("acme", "site-a")

    assert_received {[:mishka_pay, :credentials, :stop], ^ref, _,
                     %{tenant: "site-a", outcome: :ok} = meta}

    refute inspect(meta) =~ "sk_test"
  end

  test "a time limit that is not milliseconds or :infinity is refused" do
    for timeout <- [-1, nil, "5s"] do
      assert_raise ArgumentError, ~r/timeout/, fn ->
        Credentials.fetch("acme", nil, timeout: timeout)
      end
    end
  end

  @tag :capture_log
  test "a plugin that raises leaves the keys missing, never half read" do
    MishkaPay.Test.start_plugin!(SiteKeys)

    assert {:error, %Errors.MissingCredentials{reason: :raised}} =
             Credentials.fetch("acme", "site-boom")
  end
end

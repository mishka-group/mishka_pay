# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.TestKitTest do
  # The kit's keys and HTTP stubs belong to each test, so these run side by side.
  use ExUnit.Case, async: true

  alias MishkaPay.{Client, Credentials, Errors, ProviderCase}

  test "put_keys answers this test's keys, for one tenant or for every tenant" do
    MishkaPay.Test.put_keys("acme", %{secret_key: "sk_test_any"})
    MishkaPay.Test.put_keys("acme", %{secret_key: "sk_test_a"}, "site-a")

    assert {:ok, %{secret_key: "sk_test_a"}} = Credentials.fetch("acme", "site-a")
    assert {:ok, %{secret_key: "sk_test_any"}} = Credentials.fetch("acme", "site-b")
    assert {:error, %Errors.MissingCredentials{}} = Credentials.fetch("other", "site-a")
  end

  test "a task the test starts sees its keys, and a process it did not start does not" do
    MishkaPay.Test.put_keys("acme", %{secret_key: "sk_test_task"})

    assert {:ok, %{secret_key: "sk_test_task"}} =
             fn -> Credentials.fetch("acme") end |> Task.async() |> Task.await()

    test = self()
    stranger = spawn(fn -> send(test, {:stranger, Credentials.fetch("acme")}) end)
    ref = Process.monitor(stranger)

    assert_receive {:stranger, {:error, %Errors.MissingCredentials{}}}
    assert_receive {:DOWN, ^ref, :process, ^stranger, :normal}
  end

  test "keys put by another test are never seen" do
    other =
      Task.async(fn ->
        MishkaPay.Test.Keys.put(self(), "acme", :any, %{secret_key: "sk_test_other"})
        :ok
      end)

    Task.await(other)
    assert {:error, %Errors.MissingCredentials{}} = Credentials.fetch("acme")
  end

  test "stub_http answers every client request of this test" do
    MishkaPay.Test.stub_http(&Req.Test.json(&1, %{"id" => "ch_1"}))

    assert {:ok, %Req.Response{status: 200, body: %{"id" => "ch_1"}}} =
             Client.request(%{
               provider: "acme",
               base_url: "https://api.acme.test",
               path: "/v1/charges"
             })
  end

  test "the contract fails for a module that is not a provider, naming what is missing" do
    error = assert_raise ExUnit.AssertionError, fn -> ProviderCase.assert_callbacks(Enum) end
    assert error.message =~ "does not implement"
  end
end

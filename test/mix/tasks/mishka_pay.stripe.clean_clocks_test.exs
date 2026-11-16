# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.MishkaPay.Stripe.CleanClocksTest do
  # Starts the Stripe plugin, which changes the providers event every test sees.
  use ExUnit.Case, async: false

  alias Mix.Tasks.MishkaPay.Stripe.CleanClocks
  alias MishkaPay.Providers.Stripe

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_123"})
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    now = System.os_time(:second)
    test = self()

    clocks = [
      clock("clock_1OldE2e", "e2e renewal", now - 3 * 3600),
      clock("clock_1OldOther", "billing demo", now - 3 * 3600),
      clock("clock_1NewE2e", "e2e fresh", now - 60)
    ]

    MishkaPay.Test.stub_http(fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, %{"object" => "list", "data" => clocks, "has_more" => false})

        "DELETE" ->
          id = conn.path_info |> List.last()
          send(test, {:deleted, id})

          Req.Test.json(conn, %{
            "id" => id,
            "object" => "test_helpers.test_clock",
            "deleted" => true
          })
      end
    end)
  end

  test "deletes only the clocks older than asked whose name starts as asked" do
    CleanClocks.run(~w(--name e2e --older-than 1))

    assert_received {:deleted, "clock_1OldE2e"}
    refute_received {:deleted, _other}
    assert_received {:mix_shell, :info, ["deleted clock_1OldE2e e2e renewal"]}
  end

  test "--older-than 0 takes every clock" do
    CleanClocks.run(~w(--older-than 0))

    for id <- ~w(clock_1OldE2e clock_1OldOther clock_1NewE2e),
        do: assert_received({:deleted, ^id})
  end

  test "--dry-run lists what it would delete and deletes nothing" do
    CleanClocks.run(~w(--dry-run))

    refute_received {:deleted, _id}
    assert_received {:mix_shell, :info, ["would delete clock_1OldE2e e2e renewal"]}
    assert_received {:mix_shell, :info, ["would delete clock_1OldOther billing demo"]}
  end

  defp clock(id, name, created) do
    %{
      "id" => id,
      "object" => "test_helpers.test_clock",
      "name" => name,
      "created" => created,
      "frozen_time" => created,
      "status" => "ready"
    }
  end
end

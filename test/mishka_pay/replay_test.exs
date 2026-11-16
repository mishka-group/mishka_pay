# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.ReplayTest do
  # Starts plugins, which changes the events every test sees.
  use ExUnit.Case, async: false

  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Support.EventListener

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.start_plugin!(EventListener)
    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_a"}, "site-a")
    :ok
  end

  defp event(id, type, created),
    do: %{
      "id" => id,
      "object" => "event",
      "type" => type,
      "created" => created,
      "livemode" => false,
      "data" => %{"object" => %{"object" => "payment_intent", "id" => "pi_#{id}"}}
    }

  # Stripe answers newest first, a page of two, then the last page; it tells the test each query.
  defp stripe do
    test_pid = self()

    MishkaPay.Test.stub_http(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:query, conn.query_string})

      case conn.query_params["starting_after"] do
        nil ->
          Req.Test.json(conn, %{
            "data" => [
              event("evt_3", "payment_intent.succeeded", 1_794_000_300),
              event("evt_2", "listener.fails", 1_794_000_200)
            ],
            "has_more" => true
          })

        "evt_2" ->
          Req.Test.json(conn, %{
            "data" => [event("evt_1", "payment_intent.succeeded", 1_794_000_100)],
            "has_more" => false
          })
      end
    end)
  end

  test "the events a site missed are delivered again oldest first, with the site, and failures named" do
    stripe()
    since = DateTime.from_unix!(1_794_000_000)

    assert {:ok, %{delivered: 2, failed: [{"evt_2", "the inbox is full"}]}} =
             MishkaPay.replay_events("stripe", "site-a",
               since: since,
               types: ["payment_intent.succeeded", "listener.fails"]
             )

    assert_received {:query, query}
    assert URI.decode_query(query)["created[gte]"] == "1794000000"
    assert query =~ "types%5B%5D=listener.fails"

    assert_received {:webhook_event, %MishkaPay.Event{id: "evt_1", tenant: "site-a"}}
    assert_received {:webhook_event, %MishkaPay.Event{id: "evt_3", payment_id: "pi_evt_3"}}
  end

  test "by default only the events Mishka Pay acts on are asked for, at most 20 types a call" do
    stripe()

    assert {:ok, _replayed} =
             MishkaPay.replay_events("stripe", "site-a", since: DateTime.utc_now())

    queries = for {:query, query} <- collect(), do: URI.query_decoder(query) |> Enum.to_list()

    asked =
      for query <- queries, {"types[]", type} <- query, uniq: true, do: type

    assert Enum.sort(asked) == Stripe.handled_events() |> Map.keys() |> Enum.sort()

    assert Enum.all?(queries, fn query -> Enum.count(query, &(elem(&1, 0) == "types[]")) <= 20 end)
  end

  test "more than 20 types in one call is refused before any request" do
    MishkaPay.Test.stub_http(fn _conn -> flunk("no request") end)
    types = for n <- 1..21, do: "type.#{n}"

    assert {:error, %MishkaPay.Errors.Invalid{errors: [%{field: :types}]}} =
             MishkaPay.list_events("stripe", "site-a", types: types)
  end

  defp collect do
    receive do
      message -> [message | collect()]
    after
      0 -> []
    end
  end
end

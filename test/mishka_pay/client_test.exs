# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.ClientTest do
  # Req.Test stubs are owned by the test process, and the telemetry handler is attached per test.
  use ExUnit.Case, async: true

  alias GuardedStruct.Errors.Validation
  alias MishkaPay.{Client, Errors}

  defp request(attrs) do
    %{
      provider: "acme",
      base_url: "https://api.acme.test",
      path: "/v1/things",
      retry_delay: 0,
      options: [plug: {Req.Test, __MODULE__}]
    }
    |> Map.merge(attrs)
    |> Client.request()
  end

  # Answers `statuses` in turn and tells the test what each attempt carried.
  defp answer(statuses) do
    {:ok, left} = Agent.start_link(fn -> statuses end)
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      status = Agent.get_and_update(left, fn [now | rest] -> {now, rest} end)
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:attempt, conn.method, conn.request_path, conn.query_string, body,
         Map.new(conn.req_headers)}
      )

      conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"status" => status})
    end)
  end

  test "a read sends its path, query and auth, and answers the decoded body" do
    answer([200])

    assert {:ok, %Req.Response{status: 200, body: %{"status" => 200}}} =
             request(%{params: [limit: 3], auth: {:bearer, "sk_test_1"}})

    assert_received {:attempt, "GET", "/v1/things", "limit=3", "", headers}
    assert headers["authorization"] == "Bearer sk_test_1"
    refute Map.has_key?(headers, "idempotency-key")
  end

  test "a write sends its form and one idempotency key, the same on every retry" do
    answer([503, 500, 200])

    assert {:ok, %Req.Response{status: 200}} =
             request(%{
               method: :post,
               form: [amount: 1999],
               idempotency_header: "Idempotency-Key"
             })

    assert_received {:attempt, "POST", _, _, "amount=1999", %{"idempotency-key" => key}}
    assert_received {:attempt, "POST", _, _, _, %{"idempotency-key" => ^key}}
    assert_received {:attempt, "POST", _, _, _, %{"idempotency-key" => ^key}}
    assert "mp_" <> _ = key
  end

  test "the caller's own idempotency key is the one sent" do
    answer([200])

    request(%{method: :post, idempotency_header: "idempotency-key", idempotency_key: "order-42"})

    assert_received {:attempt, "POST", _, _, _, %{"idempotency-key" => "order-42"}}
  end

  test "a write to a provider without idempotency keys is never sent twice" do
    answer([503, 200])

    assert {:ok, %Req.Response{status: 503}} = request(%{method: :post, form: [amount: 1]})

    assert_received {:attempt, "POST", _, _, _, _}
    refute_received {:attempt, _, _, _, _, _}
  end

  test "a read gives up after max_retries and answers the last status" do
    answer([500, 500, 500, 200])

    assert {:ok, %Req.Response{status: 500}} = request(%{max_retries: 2})
  end

  test "a status that is not worth retrying is answered at once" do
    answer([402, 200])

    assert {:ok, %Req.Response{status: 402}} = request(%{method: :post, idempotency_header: "k"})
    assert_received {:attempt, _, _, _, _, _}
    refute_received {:attempt, _, _, _, _, _}
  end

  test "a provider that never answers is unreachable, in the provider class" do
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Errors.Unreachable{provider: "acme"} = error} = request(%{})
    assert Exception.message(error) =~ "refused"
    assert %Errors.Provider{} = Errors.to_class(error)
  end

  test "telemetry tells the provider, method and status, never the auth" do
    answer([200])
    ref = make_ref()
    test = self()
    events = [[:mishka_pay, :request, :start], [:mishka_pay, :request, :stop]]

    :telemetry.attach_many(
      inspect(ref),
      events,
      fn event, _measurements, meta, _config -> send(test, {ref, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(inspect(ref)) end)

    request(%{auth: {:bearer, "sk_test_secret"}})

    assert_received {^ref, [:mishka_pay, :request, :start], %{provider: "acme", method: :get}}
    assert_received {^ref, [:mishka_pay, :request, :stop], %{status: 200} = meta}
    refute inspect(meta) =~ "sk_test_secret"
  end

  test "a request that is not valid is refused before anything is sent" do
    assert {:error, %Errors.Invalid{errors: [%Validation{field: :base_url}]}} =
             Client.request(%{provider: "acme", path: "/x"})

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :method}]}} =
             Client.request(%{
               provider: "acme",
               method: :fetch,
               base_url: "https://x",
               path: "/x"
             })
  end

  test "a Retry-After header is waited for when it is whole seconds, and ignored when it is not" do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, :attempt)

      case Process.get(:answered) do
        nil ->
          Process.put(:answered, true)

          conn
          |> Plug.Conn.put_resp_header("retry-after", "garbage")
          |> Plug.Conn.send_resp(429, "")

        true ->
          Req.Test.json(conn, %{})
      end
    end)

    assert {:ok, %Req.Response{status: 200}} = request(%{})
    assert_received :attempt
    assert_received :attempt
  end

  test "a long Retry-After is never waited longer than max_wait" do
    started = System.monotonic_time(:millisecond)

    Req.Test.stub(__MODULE__, fn conn ->
      case Process.get(:answered) do
        nil ->
          Process.put(:answered, true)

          conn
          |> Plug.Conn.put_resp_header("retry-after", "86400")
          |> Plug.Conn.send_resp(503, "")

        true ->
          Req.Test.json(conn, %{})
      end
    end)

    assert {:ok, %Req.Response{status: 200}} = request(%{max_wait: 50})
    assert System.monotonic_time(:millisecond) - started < 5_000
  end

  test "options cannot turn retries back on for a write without an idempotency key" do
    answer([503, 200])

    assert {:ok, %Req.Response{status: 503}} =
             request(%{method: :post, options: [plug: {Req.Test, __MODULE__}, retry: :transient]})

    assert_received {:attempt, "POST", _, _, _, _}
    refute_received {:attempt, _, _, _, _, _}
  end

  test "a header named like the idempotency header in another case is replaced, not doubled" do
    answer([200])

    request(%{
      method: :post,
      headers: %{"Idempotency-Key" => "other"},
      idempotency_header: "idempotency-key",
      idempotency_key: "order-42"
    })

    assert_received {:attempt, "POST", _, _, _, %{"idempotency-key" => "order-42"}}
  end

  test "an address, path, query or body that could misroute the request is refused" do
    base = %{provider: "acme", base_url: "https://api.acme.test", path: "/v1/x"}

    for {field, attrs} <- [
          base_url: %{base_url: "nothing"},
          base_url: %{base_url: "ftp://api.acme.test"},
          base_url: %{base_url: "https://user:pw@api.acme.test"},
          base_url: %{base_url: "https://api.acme.test?a=1"},
          path: %{path: "https://evil.test/x"},
          path: %{path: "//evil.test/x"},
          path: %{path: "no-slash"},
          path: %{path: "/v1/x?key=secret"},
          path: %{path: "/a\nb"},
          path: %{path: "/a/../b"},
          path: %{path: "/%2F%2Fevil"},
          path: %{path: "/a\\b"},
          params: %{params: [a: [1, 2]]},
          params: %{params: %{a: %{b: 1}}},
          params: %{params: [:a]},
          idempotency_header: %{idempotency_header: ""},
          json: %{form: [a: 1], json: %{a: 1}}
        ] do
      assert {:error, %Errors.Invalid{errors: [%Validation{field: ^field}]}} =
               Client.request(Map.merge(base, attrs))
    end
  end

  test "inspect leaves out the auth" do
    {:ok, spec} =
      Client.builder(%{
        provider: "acme",
        base_url: "https://x",
        path: "/",
        auth: {:bearer, "sk_1"}
      })

    refute inspect(spec) =~ "sk_1"
  end
end

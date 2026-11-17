# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.ClientTest do
  # Req.Test stubs are owned by the test process, and the telemetry handler is attached per test.
  use ExUnit.Case, async: true

  alias GuardedStruct.Errors.Validation
  alias MishkaPay.{Client, Errors, RequestOptions}

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

  test "a multipart body goes as multipart/form-data, with each part's name, filename and type" do
    answer([503, 200])
    png = <<0x89, "PNG", 0, 1, 2>>

    assert {:ok, %Req.Response{status: 200}} =
             request(%{
               method: :post,
               idempotency_header: "idempotency-key",
               multipart: [
                 {"purpose", "dispute_evidence"},
                 {"file", {png, filename: "log \"1\".png", content_type: "image/png"}}
               ]
             })

    # Each try encodes the parts again, under its own boundary, with the same idempotency key.
    keys =
      for _try <- 1..2 do
        assert_received {:attempt, "POST", "/v1/things", "", body, headers}
        assert "multipart/form-data; boundary=" <> boundary = headers["content-type"]
        assert headers["content-length"] == Integer.to_string(byte_size(body))

        assert body ==
                 "--#{boundary}\r\ncontent-disposition: form-data; name=\"purpose\"\r\n\r\n" <>
                   "dispute_evidence\r\n" <>
                   "--#{boundary}\r\ncontent-disposition: form-data; name=\"file\"; " <>
                   "filename=\"log %221%22.png\"\r\ncontent-type: image/png\r\n\r\n" <>
                   png <> "\r\n--#{boundary}--\r\n"

        headers["idempotency-key"]
      end

    assert [key, key] = keys
    assert "mp_" <> _ = key
  end

  test "a multipart part is bytes in memory only, never a path, a stream or a second body" do
    base = %{provider: "acme", base_url: "https://api.acme.test", path: "/v1/x", method: :post}

    for parts <- [
          [],
          [{"file", File.stream!(__ENV__.file)}],
          [{"file", {File.stream!(__ENV__.file), filename: "x"}}],
          [{"file", {"bytes", path: "/etc/passwd"}}],
          [{"file", {"bytes", filename: :x}}],
          [{"file", 1}],
          [:file],
          %{"file" => "bytes"}
        ] do
      assert {:error, %Errors.Invalid{errors: [%Validation{field: :multipart}]}} =
               Client.request(Map.put(base, :multipart, parts)),
             inspect(parts)
    end

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :multipart}]}} =
             Client.request(Map.merge(base, %{form: [a: 1], multipart: [{"a", "1"}]}))
  end

  test "options cannot swap the multipart body" do
    answer([200])

    request(%{
      method: :post,
      multipart: [{"a", "1"}],
      options: [plug: {Req.Test, __MODULE__}, form_multipart: [{"b", "2"}], form: [c: 3]]
    })

    assert_received {:attempt, "POST", _, _, body, _headers}
    assert body =~ "name=\"a\"\r\n\r\n1\r\n"
    refute body =~ "name=\"b\""
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

  # Answers `status` with `retry_after` once, then 200.
  defp retry_once(status, retry_after) do
    Req.Test.stub(__MODULE__, fn conn ->
      case Process.put(:answered, true) do
        nil ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", retry_after)
          |> Plug.Conn.send_resp(status, "")

        true ->
          Req.Test.json(conn, %{})
      end
    end)
  end

  defp watch_retries,
    do: :telemetry_test.attach_event_handlers(self(), [[:mishka_pay, :request, :retry]])

  test "a whole-second Retry-After is the wait, and anything else falls back to retry_delay" do
    ref = watch_retries()

    retry_once(429, "2")
    assert {:ok, %Req.Response{status: 200}} = request(%{path: "/v1/ra-two", max_wait: 0})

    assert_received {[:mishka_pay, :request, :retry], ^ref, %{wait: 0},
                     %{path: "/v1/ra-two", status: 429, retry_after: 2000, attempt: 1}}

    Process.delete(:answered)
    retry_once(429, "garbage")
    assert {:ok, %Req.Response{status: 200}} = request(%{path: "/v1/ra-garbage"})

    assert_received {[:mishka_pay, :request, :retry], ^ref, %{wait: 0},
                     %{path: "/v1/ra-garbage", retry_after: nil}}
  end

  test "a long Retry-After is never waited longer than max_wait" do
    ref = watch_retries()
    retry_once(503, "86400")

    assert {:ok, %Req.Response{status: 200}} = request(%{path: "/v1/ra-long", max_wait: 0})

    assert_received {[:mishka_pay, :request, :retry], ^ref, %{wait: 0},
                     %{path: "/v1/ra-long", retry_after: 86_400_000}}
  end

  test "a network error is retried with the doubling delay, capped by max_wait" do
    ref = watch_retries()
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Errors.Unreachable{}} =
             request(%{path: "/v1/net", retry_delay: 1, max_wait: 2, max_retries: 3})

    waits =
      for attempt <- 1..3 do
        assert_received {[:mishka_pay, :request, :retry], ^ref, %{wait: wait},
                         %{path: "/v1/net", reason: :econnrefused, attempt: ^attempt}}

        wait
      end

    assert waits == [1, 2, 2]
    refute_received {[:mishka_pay, :request, :retry], ^ref, _, %{path: "/v1/net"}}
  end

  # Answers each `{status, headers}` in turn, and tells the test each attempt it got.
  defp answer_with(answers) do
    {:ok, left} = Agent.start_link(fn -> answers end)
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {status, headers} = Agent.get_and_update(left, fn [now | rest] -> {now, rest} end)
      send(test, {:attempt, conn.method, conn.request_path})

      headers
      |> Enum.reduce(conn, fn {name, value}, conn ->
        Plug.Conn.put_resp_header(conn, name, value)
      end)
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"status" => status})
    end)
  end

  @told %{retry_header: "Stripe-Should-Retry", limit_header: "stripe-rate-limited-reason"}

  test "the provider's should-retry header retries a status that is not on the list, and its false stops a retry" do
    answer_with([{409, [{"stripe-should-retry", "true"}]}, {200, []}])

    assert {:ok, %Req.Response{status: 200}} =
             request(Map.merge(@told, %{method: :post, idempotency_header: "idempotency-key"}))

    assert_received {:attempt, "POST", _path}
    assert_received {:attempt, "POST", _path}

    answer_with([{503, [{"stripe-should-retry", "false"}]}, {200, []}])
    assert {:ok, %Req.Response{status: 503}} = request(@told)
    assert_received {:attempt, "GET", _path}
    refute_received {:attempt, _method, _path}
  end

  test "a should-retry true on an answer that did not fail is never sent again" do
    answer_with([{200, [{"stripe-should-retry", "true"}]}, {200, []}])
    assert {:ok, %Req.Response{status: 200}} = request(@told)
    assert_received {:attempt, "GET", _path}
    refute_received {:attempt, _method, _path}
  end

  test "a should-retry true never sends a write twice without its idempotency key" do
    answer_with([{409, [{"stripe-should-retry", "true"}]}, {200, []}])

    assert {:ok, %Req.Response{status: 409}} = request(Map.merge(@told, %{method: :post}))
    assert_received {:attempt, "POST", _path}
    refute_received {:attempt, _method, _path}
  end

  test "without a should-retry header the status decides, as before" do
    answer_with([{409, []}, {200, []}])
    assert {:ok, %Req.Response{status: 409}} = request(@told)
    assert_received {:attempt, "GET", _path}
    refute_received {:attempt, _method, _path}
  end

  test "the rate-limit reason is in the retry and stop telemetry" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:mishka_pay, :request, :retry],
        [:mishka_pay, :request, :stop]
      ])

    answer_with([
      {429, [{"stripe-rate-limited-reason", "endpoint-concurrency"}]},
      {429, [{"stripe-rate-limited-reason", "global-rate"}]}
    ])

    assert {:ok, %Req.Response{status: 429}} =
             request(Map.merge(@told, %{path: "/v1/limited", max_retries: 1}))

    assert_received {[:mishka_pay, :request, :retry], ^ref, %{wait: 0},
                     %{
                       path: "/v1/limited",
                       status: 429,
                       rate_limit_reason: "endpoint-concurrency"
                     }}

    assert_received {[:mishka_pay, :request, :stop], ^ref, _measurements,
                     %{path: "/v1/limited", status: 429, rate_limit_reason: "global-rate"}}
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

  test "request options take a version and expand paths, and no field that could become a header" do
    assert {:ok, %RequestOptions{api_version: "2026-10-28.endive", expand: ["data.customer"]}} =
             RequestOptions.builder(%{
               api_version: "2026-10-28.endive",
               expand: ["data.customer"]
             })

    for {field, attrs} <- [
          api_version: %{api_version: "2026-10-28\r\nAuthorization: Bearer x"},
          api_version: %{api_version: "a b"},
          expand: %{expand: ["a.b.c.d.e"]},
          expand: %{expand: ["Customer"]},
          expand: %{expand: [:customer]},
          expand: %{expand: Enum.map(1..21, &"f#{&1}")}
        ] do
      assert {:error, [%{field: ^field} | _]} = RequestOptions.builder(attrs)
    end

    assert {:error, _unknown} = RequestOptions.builder(%{headers: %{"authorization" => "x"}})
    assert {:error, _unknown} = RequestOptions.builder(%{idempotency_key: "k"})
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

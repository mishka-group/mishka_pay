# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.StripeMock do
  @moduledoc """
  Stripe's own mock server, [stripe-mock](https://github.com/stripe/stripe-mock), behind the test
  kit's HTTP stub: `forward/1` sends each request a test makes on to it and answers with what it
  said. stripe-mock checks every request against Stripe's OpenAPI spec and answers with Stripe's
  own fixtures, so a wrong param is a 400 here as it would be at Stripe.

  Start it with `docker run -d -p 12111:12111 stripe/stripe-mock:latest`. Tests tagged
  `:stripe_mock` are left out of a run when it is not up.
  """

  @url "http://localhost:12111"

  @doc "Whether stripe-mock answers."
  @spec available?() :: boolean()
  def available? do
    match?({:ok, %Req.Response{}}, Req.get(@url, retry: false, receive_timeout: 1_000))
  end

  @doc """
  A `MishkaPay.Test.stub_http/1` plug that forwards the request to stripe-mock, or to `url`, such
  as `"https://api.stripe.com"` for the tests against a real test account, and answers with its
  status, body and `Request-Id` header.

  It waits as long as `MishkaPay.Client` waits in production (30 seconds), and a request that
  gets no answer comes back to the client as the same transport error, so the client retries it
  as it would in production (a read, or a write with its idempotency key) instead of the test
  crashing on a slow sandbox answer.
  """
  @spec forward(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def forward(conn, url \\ @url) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send_on(conn, body, url)
  end

  @doc """
  As `forward/1`, after telling `pid` what the request sent:
  `{:stripe_sent, method, path, params, idempotency_key}`, with the query and the form body
  decoded into one map of Stripe's flat names (`"line_items[0][tax_rates][0]"`). stripe-mock still
  checks the request, so a test sees both what went and that Stripe's spec takes it.
  """
  @spec forward_telling(Plug.Conn.t(), pid()) :: Plug.Conn.t()
  def forward_telling(conn, pid) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    params = [conn.query_string, body] |> Enum.reject(&(&1 == "")) |> Enum.join("&")
    key = conn |> Plug.Conn.get_req_header("idempotency-key") |> List.first()
    send(pid, {:stripe_sent, conn.method, conn.request_path, URI.decode_query(params), key})
    send_on(conn, body, @url)
  end

  defp send_on(conn, body, url) do
    Req.request(
      method: conn.method,
      url: url <> conn.request_path <> query(conn.query_string),
      headers: conn.req_headers,
      body: body,
      decode_body: false,
      retry: false,
      receive_timeout: 30_000
    )
    |> answered(conn)
  end

  defp answered({:error, %Req.TransportError{reason: reason}}, conn),
    do: Req.Test.transport_error(conn, reason)

  defp answered({:ok, answer}, conn) do
    answer.headers
    |> Map.take(["request-id"])
    |> Enum.reduce(conn, fn {name, [value | _]}, conn ->
      Plug.Conn.put_resp_header(conn, name, value)
    end)
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(answer.status, answer.body)
  end

  @doc """
  A `MishkaPay.Test.stub_http/1` plug for the tests against a real test account: it forwards an
  upload to `https://files.stripe.com` and a meter event stream report to
  `https://meter-events.stripe.com`, the hosts they were made for, and anything else to
  `https://api.stripe.com`.
  """
  @spec forward_live(Plug.Conn.t()) :: Plug.Conn.t()
  def forward_live(%Plug.Conn{host: host} = conn)
      when host in ["files.stripe.com", "meter-events.stripe.com"],
      do: forward(conn, "https://" <> host)

  def forward_live(conn), do: forward(conn, "https://api.stripe.com")

  defp query(""), do: ""
  defp query(query), do: "?" <> query
end

defmodule ShopWeb.StripeStub do
  @moduledoc """
  Stripe's answers for the shop's LiveView tests: the demo site gets test keys
  (`MishkaPay.Test.put_keys/3`) and every Mishka Pay HTTP call is answered by `answer`
  (`MishkaPay.Test.stub_http/1`), a function of the method, the path and the params (query and
  form body together). It answers a map (200), `{status, map}`, or `nil` for the default: an
  empty list on a `GET`, else Stripe's "no such object".
  """

  @doc "Gives the demo site test keys and answers Stripe with `answer`."
  def stub(answer) when is_function(answer, 3) do
    MishkaPay.Test.put_keys(
      "stripe",
      %{secret_key: "sk_test_shop", webhook_secret: "whsec_test_shop"},
      "demo"
    )

    MishkaPay.Test.stub_http(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = Map.merge(conn.query_params, form(conn, body))

      case answer.(conn.method, conn.request_path, params) do
        nil -> default(conn)
        {status, json} -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(json)
        json -> Req.Test.json(conn, json)
      end
    end)
  end

  @doc "A Stripe list of `data`."
  def list(data), do: %{"object" => "list", "data" => data, "has_more" => false}

  @doc "A Stripe error answer: `{400, ...}` with its `message` and `code`."
  def error(message, code \\ "parameter_invalid") do
    {400,
     %{"error" => %{"type" => "invalid_request_error", "message" => message, "code" => code}}}
  end

  # A form body as params; a file upload (multipart) only by its parts' names.
  defp form(conn, body) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      ["application/x-www-form-urlencoded" <> _rest] -> Plug.Conn.Query.decode(body)
      ["multipart/form-data" <> _rest] -> %{"multipart" => body}
      _other -> %{}
    end
  end

  defp default(%{method: "GET"} = conn), do: Req.Test.json(conn, list([]))

  defp default(conn) do
    {status, json} = error("No such object: #{conn.request_path}", "resource_missing")
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(json)
  end
end

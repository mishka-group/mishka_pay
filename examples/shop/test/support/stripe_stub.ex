defmodule ShopWeb.StripeStub do
  @moduledoc """
  Stripe for the shop's LiveView tests: the site's test keys (`MishkaPay.Test.put_keys/3`) and an
  answer for each Stripe call (`MishkaPay.Test.stub_http/1`), so no test reaches Stripe.

  `routes` maps `{method, path}` to Stripe's JSON answer, to `{status, json}`, or to a function
  of the request's params giving either. Every request is sent to the test as
  `{:stripe, method, path, params}`, so a test asserts what was asked. A read with no route is an
  empty list (the page's other parts read Stripe's lists when it opens); any other call with no
  route is answered 404 the way Stripe answers it.
  """

  @doc "Answers Stripe's calls of this test from `routes`, with keys for the demo site."
  def stub(routes, keys \\ %{}) do
    test = self()

    MishkaPay.Test.put_keys(
      "stripe",
      Map.merge(%{secret_key: "sk_test_shop", publishable_key: "pk_test_shop"}, keys)
    )

    MishkaPay.Test.stub_http(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = Plug.Conn.Query.decode(Enum.join([conn.query_string, body], "&"))
      send(test, {:stripe, conn.method, conn.request_path, params})

      case answer(conn.method, Map.get(routes, {conn.method, conn.request_path}), params) do
        {status, json} -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(json)
        json -> Req.Test.json(conn, json)
      end
    end)
  end

  @doc "Stripe's error answer, with its HTTP status."
  def error(status, message, param \\ nil) do
    {status,
     %{"error" => %{"type" => "invalid_request_error", "message" => message, "param" => param}}}
  end

  @doc "One page of a Stripe list."
  def list(items), do: %{"object" => "list", "data" => items, "has_more" => false}

  defp answer("GET", nil, _params), do: list([])
  defp answer(_method, nil, _params), do: error(404, "No such route in this test.")
  defp answer(_method, fun, params) when is_function(fun, 1), do: fun.(params)
  defp answer(_method, json, _params), do: json
end

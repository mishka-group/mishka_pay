# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.PayPalStub do
  @moduledoc """
  A stand-in for PayPal's REST API behind the test kit's HTTP stub, answering in PayPal's own
  shapes (Orders v2, captures, refunds, OAuth, webhook verification) from what the test set up.
  It keeps the orders of the running test in its process, and tells the test every request it
  got as `{:paypal, method, path, headers, body}`.

  `order/2` puts an Order in a state; `forward/1` is the plug.
  """

  import Plug.Conn

  @doc "Keeps the Order `id` for this test, in PayPal's `status` (APPROVED, COMPLETED...) with `opts`."
  def order(id, status, opts \\ []) do
    orders = Process.get(:paypal_orders, %{})
    Process.put(:paypal_orders, Map.put(orders, id, build(id, status, opts)))
    :ok
  end

  @doc "The plug for `MishkaPay.Test.stub_http/1`."
  def forward(conn) do
    {:ok, body, conn} = read_body(conn)
    json = if body == "", do: %{}, else: decode(body)
    send(test(), {:paypal, conn.method, conn.request_path, Map.new(conn.req_headers), json})
    answer(conn, conn.method, String.split(conn.request_path, "/", trim: true), json)
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, json} -> json
      {:error, _form} -> URI.decode_query(body)
    end
  end

  defp answer(conn, "POST", ["v1", "oauth2", "token"], _body) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> credentials] ->
        case Base.decode64!(credentials) do
          "client_bad:" <> _ ->
            reply(conn, 401, %{
              "error" => "invalid_client",
              "error_description" => "Client Authentication failed"
            })

          _ok ->
            reply(conn, 200, %{
              "access_token" => "A21_token_#{System.unique_integer([:positive])}",
              "expires_in" => 32_400
            })
        end
    end
  end

  defp answer(conn, "POST", ["v2", "checkout", "orders"], body) do
    id = "ORDER" <> Integer.to_string(System.unique_integer([:positive]))
    unit = hd(body["purchase_units"])

    case get_in(body, ["payment_source", "paypal", "experience_context", "return_url"]) do
      nil ->
        reply(conn, 422, %{
          "name" => "UNPROCESSABLE_ENTITY",
          "details" => [%{"issue" => "MISSING_RETURN_URL"}]
        })

      _url ->
        order =
          build(id, "PAYER_ACTION_REQUIRED", amount: unit["amount"], custom_id: unit["custom_id"])

        Process.put(:paypal_orders, Map.put(Process.get(:paypal_orders, %{}), id, order))
        reply(conn, 200, order)
    end
  end

  defp answer(conn, "GET", ["v2", "checkout", "orders", id], _body) do
    case Process.get(:paypal_orders, %{})[id] do
      nil ->
        reply(conn, 404, %{
          "name" => "RESOURCE_NOT_FOUND",
          "details" => [%{"issue" => "INVALID_RESOURCE_ID"}]
        })

      order ->
        reply(conn, 200, order)
    end
  end

  defp answer(conn, "POST", ["v2", "checkout", "orders", id, "capture"], _body) do
    order = Process.get(:paypal_orders)[id]

    case order["payment_source"]["paypal"]["declined"] do
      true ->
        reply(conn, 422, %{
          "name" => "UNPROCESSABLE_ENTITY",
          "details" => [%{"issue" => "INSTRUMENT_DECLINED"}]
        })

      _paid ->
        captured =
          build(id, "COMPLETED",
            amount: hd(order["purchase_units"])["amount"],
            captures: [capture(id)]
          )

        Process.put(:paypal_orders, Map.put(Process.get(:paypal_orders), id, captured))
        reply(conn, 201, captured)
    end
  end

  defp answer(conn, "POST", ["v2", "payments", "captures", "CAPTURE" <> id, "refund"], body) do
    refund = %{
      "id" => "REFUND#{System.unique_integer([:positive])}",
      "status" => "COMPLETED",
      "amount" => body["amount"] || %{"currency_code" => "USD", "value" => "39.98"},
      "create_time" => "2026-11-16T10:00:00Z"
    }

    orders = Process.get(:paypal_orders)
    order = orders[id]
    unit = hd(order["purchase_units"])

    unit =
      update_in(
        unit,
        ["payments"],
        &Map.update(&1, "refunds", [refund], fn rs -> rs ++ [refund] end)
      )

    Process.put(:paypal_orders, Map.put(orders, id, %{order | "purchase_units" => [unit]}))
    reply(conn, 201, refund)
  end

  defp answer(conn, "POST", ["v1", "notifications", "verify-webhook-signature"], body) do
    status = if body["transmission_sig"] == "good", do: "SUCCESS", else: "FAILURE"
    reply(conn, 200, %{"verification_status" => status})
  end

  defp reply(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
  end

  defp build(id, status, opts) do
    amount = opts[:amount] || %{"currency_code" => "USD", "value" => "39.98"}

    payments =
      case opts[:captures] do
        nil -> %{}
        captures -> %{"captures" => captures, "refunds" => opts[:refunds] || []}
      end

    %{
      "id" => id,
      "status" => status,
      "create_time" => "2026-11-16T09:00:00Z",
      "purchase_units" => [
        %{
          "custom_id" => opts[:custom_id] || "order-1",
          "amount" => amount,
          "payments" => payments
        }
      ],
      "payer" => %{
        "payer_id" => "PAYER1",
        "email_address" => "buyer@example.com",
        "name" => %{"given_name" => "Ava", "surname" => "Martin"}
      },
      "payment_source" => %{"paypal" => %{"declined" => opts[:declined] == true}},
      "links" => [
        %{
          "rel" => "payer-action",
          "href" => "https://www.sandbox.paypal.com/checkoutnow?token=#{id}"
        }
      ]
    }
  end

  defp capture(id) do
    %{
      "id" => "CAPTURE" <> id,
      "status" => "COMPLETED",
      "amount" => %{"currency_code" => "USD", "value" => "39.98"}
    }
  end

  defp test do
    case Process.get(:"$callers") do
      [first | _] -> first
      _none -> self()
    end
  end
end

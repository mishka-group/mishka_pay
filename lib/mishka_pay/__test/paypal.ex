# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Test.PayPal do
  @moduledoc """
  A stand-in for PayPal's REST API for a project's tests: it answers in PayPal's own shapes
  (Orders v2, captures, refunds, catalog products, billing plans, subscriptions and their
  transactions, OAuth, webhook verification), so a host tests its PayPal flows with no keys and
  no network. Mishka Pay's own PayPal tests run on it, and its sandbox tests check it against
  PayPal (`mix test --only paypal_live`).

      setup do
        MishkaPay.Test.start_plugin!(MishkaPay.Providers.PayPal)
        MishkaPay.Test.put_keys("paypal", %{publishable_key: "client_1", secret_key: "secret_1",
          webhook_secret: "WH-1", mode: :test})
        MishkaPay.Test.PayPal.stub!()
      end

      test "the buyer pays and comes back" do
        {:ok, checkout} = MishkaPay.checkout(%{provider: "paypal", ...})
        MishkaPay.Test.PayPal.order(checkout.id, "APPROVED")
        {:ok, %{payment_id: _paid}} = MishkaPay.fetch_checkout("paypal", checkout.id)
      end

  `order/3` puts an Order in a state (an `"APPROVED"` one is captured when read; `declined: true`
  declines the capture), `subscription/3` a subscription (`"ACTIVE"` with `:billing_info` and
  `:transactions`). A webhook message is verified when its `paypal-transmission-sig` header is
  `"good"`.

  `MishkaPay.Test.setup!/0` makes its table. What it holds belongs to the test that called `stub!/0`, read from any process the test starts
  (through `$callers`), so async tests never see each other's. It tells the test every request
  it got as `{:paypal, method, path, headers, body}`, and its bytes as `{:paypal_raw, path, body}`.
  """

  @table __MODULE__

  @doc "Answers this test's PayPal requests with the stand-in, holding what it makes for this test."
  @spec stub!() :: :ok
  def stub! do
    test = self()
    ExUnit.Callbacks.on_exit(fn -> :ets.match_delete(@table, {{test, :_}, :_}) end)
    MishkaPay.Test.stub_http(&forward/1)
  end

  # Made by `MishkaPay.Test.setup!/0` in the test run's own process, so it outlives every test.
  @doc false
  def new_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _exists -> @table
    end
  end

  defp held(kind) do
    case :ets.lookup(@table, {test(), kind}) do
      [{_key, map}] -> map
      [] -> %{}
    end
  end

  defp hold(kind, map), do: :ets.insert(@table, {{test(), kind}, map})

  defp put_held(kind, id, value), do: hold(kind, Map.put(held(kind), id, value))

  import Plug.Conn

  @doc "Keeps the Order `id` for this test, in PayPal's `status` (APPROVED, COMPLETED...) with `opts`."
  def order(id, status, opts \\ []) do
    put_held(:orders, id, build(id, status, Keyword.merge(kept(id), opts)))
    :ok
  end

  # An Order made earlier keeps its amount and the caller's `custom_id` when only its state changes.
  defp kept(id) do
    case held(:orders)[id] do
      %{"purchase_units" => [unit | _]} -> [amount: unit["amount"], custom_id: unit["custom_id"]]
      _new -> []
    end
  end

  @doc """
  Puts the subscription `id` made earlier (or a new one) in PayPal's `status` (ACTIVE,
  SUSPENDED...): `:billing_info` and `:transactions` as PayPal would answer them.
  """
  def subscription(id, status, opts \\ []) do
    sub = Map.get(held(:subscriptions), id) || new_subscription(id, opts[:plan] || plan(%{}))

    sub =
      sub
      |> Map.put("status", status)
      |> Map.put("status_update_time", "2026-11-20T10:00:00Z")
      |> put_billing(opts[:billing_info])
      |> Map.put("transactions", opts[:transactions] || sub["transactions"] || [])

    put_held(:subscriptions, id, sub)
    :ok
  end

  defp put_billing(sub, nil), do: sub
  defp put_billing(sub, billing), do: Map.put(sub, "billing_info", billing)

  @doc "The plug `stub!/0` answers with, for `MishkaPay.Test.stub_http/1`."
  def forward(conn) do
    {:ok, body, conn} = read_body(conn)
    json = if body == "", do: %{}, else: decode(body)
    send(test(), {:paypal, conn.method, conn.request_path, Map.new(conn.req_headers), json})
    send(test(), {:paypal_raw, conn.request_path, body})
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

        put_held(:orders, id, order)
        reply(conn, 200, order)
    end
  end

  defp answer(conn, "GET", ["v2", "checkout", "orders", id], _body) do
    case held(:orders)[id] do
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
    order = held(:orders)[id]

    case order["payment_source"]["paypal"]["declined"] do
      true ->
        reply(conn, 422, %{
          "name" => "UNPROCESSABLE_ENTITY",
          "details" => [%{"issue" => "INSTRUMENT_DECLINED"}]
        })

      _paid ->
        captured =
          build(id, "COMPLETED", Keyword.put(kept(id), :captures, [capture(id)]))

        put_held(:orders, id, captured)
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

    order = held(:orders)[id]
    unit = hd(order["purchase_units"])

    unit =
      update_in(
        unit,
        ["payments"],
        &Map.update(&1, "refunds", [refund], fn rs -> rs ++ [refund] end)
      )

    put_held(:orders, id, %{order | "purchase_units" => [unit]})
    reply(conn, 201, refund)
  end

  defp answer(conn, "POST", ["v1", "catalogs", "products"], body) do
    reply(conn, 201, %{
      "id" => "PROD-#{System.unique_integer([:positive])}",
      "name" => body["name"]
    })
  end

  defp answer(conn, "POST", ["v1", "billing", "plans"], body) do
    plan = plan(body)
    put_held(:plans, plan["id"], plan)
    reply(conn, 201, Map.take(plan, ["id", "product_id", "name", "status"]))
  end

  defp answer(conn, "POST", ["v1", "billing", "subscriptions"], body) do
    id = "I-" <> paypal_id()
    plan = held(:plans)[body["plan_id"]]

    sub =
      new_subscription(id, plan)
      |> Map.merge(Map.take(body, ["quantity", "custom_id"]))
      |> Map.put("subscriber", Map.get(body, "subscriber", %{}))

    put_held(:subscriptions, id, sub)
    reply(conn, 201, Map.drop(sub, ["plan", "transactions"]))
  end

  defp answer(conn, "GET", ["v1", "billing", "subscriptions", id], _body) do
    case held(:subscriptions)[id] do
      nil -> not_found(conn)
      sub -> reply(conn, 200, Map.drop(sub, ["transactions"]))
    end
  end

  defp answer(conn, "GET", ["v1", "billing", "subscriptions", id, "transactions"], _body) do
    case held(:subscriptions)[id] do
      %{"status" => status} = sub when status not in ["APPROVAL_PENDING", "APPROVED"] ->
        reply(conn, 200, %{"transactions" => sub["transactions"], "total_items" => 1})

      _none ->
        not_found(conn)
    end
  end

  defp answer(conn, "POST", ["v1", "billing", "subscriptions", id, "cancel"], _body) do
    case held(:subscriptions)[id] do
      %{"status" => status} = sub when status in ["ACTIVE", "SUSPENDED"] ->
        canceled = Map.merge(sub, %{"status" => "CANCELLED"})
        put_held(:subscriptions, id, canceled)
        send_resp(conn, 204, "")

      _not_cancelable ->
        not_found(conn)
    end
  end

  defp answer(conn, "POST", ["v1", "notifications", "verify-webhook-signature"], body) do
    status = if body["transmission_sig"] == "good", do: "SUCCESS", else: "FAILURE"
    reply(conn, 200, %{"verification_status" => status})
  end

  # A PayPal id is twelve or more letters and digits, whatever the counter is.
  defp paypal_id,
    do:
      "SUB" <> String.pad_leading(Integer.to_string(System.unique_integer([:positive])), 10, "0")

  defp not_found(conn) do
    reply(conn, 404, %{
      "name" => "RESOURCE_NOT_FOUND",
      "details" => [%{"issue" => "INVALID_RESOURCE_ID"}]
    })
  end

  defp plan(body) do
    %{
      "id" => "P-PLAN#{System.unique_integer([:positive])}",
      "product_id" => body["product_id"] || "PROD-1",
      "name" => body["name"] || "Pro monthly",
      "status" => "ACTIVE",
      "quantity_supported" => true,
      "billing_cycles" =>
        body["billing_cycles"] ||
          [
            %{
              "tenure_type" => "REGULAR",
              "sequence" => 1,
              "total_cycles" => 0,
              "frequency" => %{"interval_unit" => "MONTH", "interval_count" => 1},
              "pricing_scheme" => %{
                "fixed_price" => %{"currency_code" => "USD", "value" => "9.0"}
              }
            }
          ]
    }
  end

  defp new_subscription(id, plan) do
    %{
      "id" => id,
      "status" => "APPROVAL_PENDING",
      "plan_id" => plan["id"],
      "plan" => Map.drop(plan, ["id", "status"]),
      "quantity" => "1",
      "custom_id" => "sub-1",
      "start_time" => "2026-11-16T09:00:00Z",
      "create_time" => "2026-11-16T09:00:00Z",
      "status_update_time" => "2026-11-16T09:00:00Z",
      "subscriber" => %{},
      "transactions" => [],
      "links" => [
        %{
          "rel" => "approve",
          "href" => "https://www.sandbox.paypal.com/webapps/billing/subscriptions?ba_token=BA-1"
        }
      ]
    }
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

  # The test: the last of the callers, as a test's tasks and their tasks carry it.
  defp test do
    case Process.get(:"$callers") do
      [_ | _] = callers -> List.last(callers)
      _none -> self()
    end
  end
end

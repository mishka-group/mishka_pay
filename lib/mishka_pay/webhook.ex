# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Webhook do
  @moduledoc """
  Receives the webhooks providers send, as a Plug. It reads the raw body, finds the provider (and the
  tenant) from the path, lets the provider check the signature with the tenant's webhook secret,
  and hands the checked `MishkaPay.Event` to the `mishka_pay:webhook:received` listeners
  (`MishkaPay.Events.webhook_received/0`). It does no work of its own.

  ## Mounting

  A signature is checked on the raw body, so the plug must see it before `Plug.Parsers` reads it.
  Put it in the endpoint, before the parsers:

      plug MishkaPay.Webhook, at: "/pay/webhooks"
      plug Plug.Parsers, ...

  Then `POST /pay/webhooks/stripe` is Stripe's for a project with one set of keys, and
  `POST /pay/webhooks/stripe/<tenant>` for one tenant's keys (`MishkaPay.Credentials`): give each
  site's endpoint that URL in the provider's dashboard. Every other request passes through.

  Mounted with `forward` in a router instead, the parsers have read the body already: keep a copy
  with `body_reader: {MishkaPay.Webhook, :read_body, ["/pay/webhooks"]}` in `Plug.Parsers`.

  ## Answers

  The provider sends a message again until it gets a 2xx, so the status says whether to:

    * `200` the event was handed over and no listener said it failed;
    * `400` a signature that cannot be trusted (`MishkaPay.Errors.BadSignature`) or a body that
      cannot be read: sending it again would not help;
    * `404` no such provider installed, or one without `:webhook`;
    * `500` no keys for the tenant, or a listener that failed, raised, exited or took longer than
      `config :mishka_pay, webhook_timeout: ms` (15 seconds): the provider tries again later.

  ## Listeners

  A listener is a mishka_installer plugin on `mishka_pay:webhook:received`. It gets `%{event:
  event, failed: nil}` and answers it with `:failed` set to a reason when it could not take the
  event. A provider may send one event twice and in any order: a listener keeps what it did by
  `event.id` and reads the object again from the provider. Mishka Pay's Ash inbox (stage 4) is
  such a listener. The listeners run like the keys plugins, in a task that cannot take the request
  down.

  ## Telemetry

  `[:mishka_pay, :webhook, :start | :stop]` with `:provider` and `:tenant`, and on `:stop` the
  `:status`, the `:outcome` and the event's `:type` and `:id` when there is one. Never a body.
  """

  @behaviour Plug

  import Plug.Conn

  alias MishkaPay.{Credentials, Errors, Events, Provider}
  alias MishkaPay.Helpers.Plugins

  @max_body 1_000_000

  @impl Plug
  def init(opts), do: Keyword.update(opts, :at, [], &String.split(&1, "/", trim: true))

  @impl Plug
  def call(conn, opts) do
    case route(conn.path_info, opts[:at]) do
      {:ok, provider, tenant} when conn.method == "POST" -> handle(conn, provider, tenant)
      {:ok, _provider, _tenant} -> conn |> send_resp(405, "") |> halt()
      :skip -> conn
    end
  end

  @doc """
  A `Plug.Parsers` `:body_reader` that keeps the raw body of requests under `prefix`, for a
  webhook plug mounted with `forward` after the parsers.
  """
  @spec read_body(Plug.Conn.t(), keyword(), String.t()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts, prefix) do
    with {status, body, conn} when status in [:ok, :more] <- Plug.Conn.read_body(conn, opts) do
      case String.starts_with?(conn.request_path, prefix) do
        true ->
          {status, body,
           put_private(
             conn,
             :mishka_pay_raw_body,
             (conn.private[:mishka_pay_raw_body] || "") <> body
           )}

        false ->
          {status, body, conn}
      end
    end
  end

  defp route(path_info, at) do
    case {Enum.split(path_info, length(at)), at} do
      {{^at, [provider]}, _at} -> {:ok, provider, nil}
      {{^at, [provider, tenant]}, _at} -> {:ok, provider, tenant}
      _elsewhere -> :skip
    end
  end

  defp handle(conn, provider, tenant) do
    meta = %{provider: provider, tenant: tenant}

    {conn, status} =
      :telemetry.span([:mishka_pay, :webhook], meta, fn ->
        {conn, status, extra} = receive_event(conn, provider, tenant)
        {{conn, status}, meta |> Map.merge(extra) |> Map.put(:status, status)}
      end)

    conn |> send_resp(status, "") |> halt()
  end

  defp receive_event(conn, provider, tenant) do
    with {:ok, payload, conn} <- raw_body(conn),
         {:ok, module} <- Provider.capable(provider, :webhook),
         {:ok, keys} <- Credentials.fetch(provider, tenant),
         {:ok, event} <- module.verify_webhook(payload, conn.req_headers, keys) do
      event = %{event | tenant: tenant}

      {conn, delivered(event), %{outcome: outcome(event), type: event.type, id: event.id}}
      |> then(fn {conn, status, extra} -> {conn, status, %{extra | outcome: outcome(status)}} end)
    else
      {:error, :too_large, conn} -> {conn, 413, %{outcome: :too_large}}
      {:error, error} -> {conn, status(error), %{outcome: reason(error)}}
    end
  end

  defp raw_body(%{private: %{mishka_pay_raw_body: body}} = conn), do: {:ok, body, conn}

  defp raw_body(conn) do
    case Plug.Conn.read_body(conn, length: @max_body) do
      {:ok, body, conn} ->
        {:ok, body, conn}

      {:more, _part, conn} ->
        {:error, :too_large, conn}

      {:error, _reason} ->
        {:error, Errors.BadSignature.exception(provider: nil, reason: :malformed)}
    end
  end

  defp delivered(event) do
    timeout = Application.get_env(:mishka_pay, :webhook_timeout, 15_000)

    case Plugins.call(Events.webhook_received(), %{event: event, failed: nil}, timeout) do
      {:ok, %{failed: nil}} -> 200
      _failed_or_no_answer -> 500
    end
  end

  defp outcome(200), do: :ok
  defp outcome(_status), do: :failed

  defp status(%Errors.UnknownProvider{}), do: 404
  defp status(%Errors.Unsupported{}), do: 404
  defp status(%Errors.MissingCredentials{}), do: 500
  defp status(_untrusted), do: 400

  defp reason(%Errors.BadSignature{reason: reason}), do: reason
  defp reason(%Errors.UnknownProvider{}), do: :unknown_provider
  defp reason(%Errors.Unsupported{}), do: :unsupported
  defp reason(%Errors.MissingCredentials{}), do: :missing_credentials
  defp reason(_invalid), do: :invalid
end

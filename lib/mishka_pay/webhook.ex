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
    * `400` a message that cannot be trusted: no keys or no webhook secret for the tenant, a
      signature that does not match (`MishkaPay.Errors.BadSignature`) or a body that cannot be
      read. The same answer for all of them, so a stranger cannot tell which tenants exist;
    * `404` no such provider installed, or one without `:webhook`;
    * `413` a body over 1 MB;
    * `500` a checked event that a listener failed to take: it set `:failed`, raised, exited or
      took longer than `config :mishka_pay, webhook_timeout: ms` (15 seconds).

  Providers send a message again on any status but 2xx, so a tenant whose keys come later still
  gets its events.

  ## Listeners

  A listener is a mishka_installer plugin on `mishka_pay:webhook:received`. It gets `%{event:
  event, failed: nil}` and answers it with `:failed` set to a reason when it could not take the
  event; anything but `nil` there counts as failed. A provider may send one event twice and in any order: a listener keeps what it did by
  `event.id` and reads the object again from the provider. Mishka Pay's Ash inbox (stage 4) is
  such a listener. The listeners run like the keys plugins, in a task that cannot take the request
  down.

  ## After the answer

  Once the answer went out, `mishka_pay:webhook:answered` (`MishkaPay.Events.webhook_answered/0`)
  tells its listeners how long the request took from coming in to its answer (`:answer_ms`),
  with the checked event, or, for a refused message, why (`:outcome`), never its body. The Ash
  inbox writes the time on the event's row and the `:webhook_rejection` kind counts the refused
  ones per provider, site, reason and day. A message to a provider that is not installed (404)
  names no provider there, and a site without keys no tenant, so a stranger cannot add names.

  ## Telemetry

  `[:mishka_pay, :webhook, :start | :stop]` with `:provider`, and on `:stop` the `:status`, the
  `:outcome`, and for a checked event its `:tenant`, `:type` and `:id`. A tenant from the path is
  reported only once the signature proves it, so strangers cannot fill metrics with made-up ones.
  `[:mishka_pay, :webhook, :answered]` follows once the answer went out, with the measurements
  `:answer_ms` and `:duration` (native time units, from taking the request in to answering it)
  and the same metadata. Never a body.
  """

  @behaviour Plug

  import Plug.Conn

  alias MishkaPay.{Credentials, Errors, Events, Provider}
  alias MishkaPay.Helpers.Plugins

  @max_body 1_000_000

  @impl Plug
  def init(opts) do
    case opts |> Keyword.get(:at, "") |> String.split("/", trim: true) do
      [] ->
        raise ArgumentError,
              ~s|MishkaPay.Webhook needs a path of its own, such as at: "/pay/webhooks"|

      at ->
        Keyword.put(opts, :at, at)
    end
  end

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
      case String.starts_with?(conn.request_path, String.trim_trailing(prefix, "/") <> "/") do
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
    started = System.monotonic_time()
    meta = %{provider: provider}

    {conn, status, meta, answer} =
      :telemetry.span([:mishka_pay, :webhook], meta, fn ->
        {conn, status, extra, answer} = receive_event(conn, provider, tenant)
        meta = meta |> Map.merge(extra) |> Map.put(:status, status)
        {{conn, status, meta, answer}, meta}
      end)

    conn = conn |> send_resp(status, "") |> halt()
    answered(answer, meta, started)
    conn
  end

  # The provider is checked before the body is read, so a refused message names a provider only
  # when one is installed with webhooks.
  defp receive_event(conn, provider, tenant) do
    answer = %{provider: nil, tenant: nil, event: nil, received_at: DateTime.utc_now()}

    case checked(conn, provider, tenant) do
      {:ok, event, conn} ->
        event = %{event | tenant: tenant, received_at: answer.received_at}
        status = delivered(event)
        outcome = outcome(status)
        extra = %{outcome: outcome, tenant: tenant, type: event.type, id: event.id}
        named = %{provider: provider, tenant: tenant, event: event, outcome: outcome}
        {conn, status, extra, Map.merge(answer, named)}

      {:error, :too_large, %Plug.Conn{} = conn} ->
        named = %{provider: provider, outcome: :too_large}
        {conn, 413, %{outcome: :too_large}, Map.merge(answer, named)}

      {:error, error, named} ->
        outcome = reason(error)

        {conn, status(error), %{outcome: outcome},
         Map.merge(answer, Map.put(named, :outcome, outcome))}
    end
  end

  # The checked event; or the refusal, with what of the path it may name: the provider once it is
  # installed with webhooks, and the tenant once it has keys.
  defp checked(conn, provider, tenant) do
    with {:ok, module} <- capable(provider),
         {:ok, payload, conn} <- raw_body(conn, provider),
         {:ok, keys} <- keys(provider, tenant) do
      case module.verify_webhook(payload, conn.req_headers, keys) do
        {:ok, event} -> {:ok, event, conn}
        {:error, error} -> {:error, error, %{provider: provider, tenant: tenant}}
      end
    end
  end

  defp capable(provider) do
    with {:error, error} <- Provider.capable(provider, :webhook), do: {:error, error, %{}}
  end

  defp keys(provider, tenant) do
    with {:error, error} <- Credentials.fetch(provider, tenant),
         do: {:error, error, %{provider: provider}}
  end

  defp answered(answer, meta, started) do
    duration = System.monotonic_time() - started
    answer_ms = System.convert_time_unit(duration, :native, :millisecond)

    :telemetry.execute(
      [:mishka_pay, :webhook, :answered],
      %{answer_ms: answer_ms, duration: duration},
      meta
    )

    timeout = Application.get_env(:mishka_pay, :webhook_timeout, 15_000)
    state = Map.merge(answer, %{status: meta.status, answer_ms: answer_ms})
    _answer = Plugins.call(Events.webhook_answered(), state, timeout)
    :ok
  end

  defp raw_body(%{private: %{mishka_pay_raw_body: body}} = conn, _provider),
    do: {:ok, body, conn}

  defp raw_body(conn, provider) do
    case Plug.Conn.read_body(conn, length: @max_body) do
      {:ok, body, conn} ->
        {:ok, body, conn}

      {:more, _part, conn} ->
        {:error, :too_large, conn}

      {:error, _reason} ->
        {:error, Errors.BadSignature.exception(provider: nil, reason: :malformed),
         %{provider: provider}}
    end
  end

  defp delivered(event) do
    case deliver(event) do
      :ok -> 200
      {:error, _reason} -> 500
    end
  end

  @doc """
  Hands a checked `MishkaPay.Event` to the `mishka_pay:webhook:received` listeners, as a webhook
  does: `:ok` when they took it, or `{:error, reason}`. `MishkaPay.replay_events/3` uses it for
  events read back from the provider; the listeners keep each event once, by its id.
  """
  @spec deliver(MishkaPay.Event.t()) :: :ok | {:error, term()}
  def deliver(%MishkaPay.Event{} = event) do
    timeout = Application.get_env(:mishka_pay, :webhook_timeout, 15_000)

    case Plugins.call(Events.webhook_received(), %{event: event, failed: nil}, timeout) do
      {:ok, %{failed: nil}} -> :ok
      {:ok, %{failed: reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp outcome(200), do: :ok
  defp outcome(_status), do: :failed

  defp status(%Errors.UnknownProvider{}), do: 404
  defp status(%Errors.Unsupported{}), do: 404
  defp status(_untrusted_or_unknown_tenant), do: 400

  defp reason(%Errors.BadSignature{reason: reason}), do: reason
  defp reason(%Errors.UnknownProvider{}), do: :unknown_provider
  defp reason(%Errors.Unsupported{}), do: :unsupported
  defp reason(%Errors.MissingCredentials{}), do: :missing_credentials
  defp reason(_invalid), do: :invalid
end

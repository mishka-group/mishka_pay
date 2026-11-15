# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Client do
  @moduledoc """
  The HTTP base every provider adapter builds on, over Req. A request is described as this
  guarded_struct and sent with `request/1`:

      MishkaPay.Client.request(%{
        provider: "stripe",
        method: :post,
        base_url: "https://api.stripe.com",
        path: "/v1/refunds",
        auth: {:bearer, keys.secret_key},
        headers: %{"stripe-version" => "2026-10-28"},
        form: [payment_intent: "pi_123"],
        idempotency_header: "idempotency-key"
      })

  What every provider gets from it:

    * **Retries.** A network error and the answers 408, 429, 500, 502, 503 and 504 are tried again,
      `max_retries` times (2 by default). The wait is what a whole-second `Retry-After` header says,
      or `retry_delay` milliseconds (500 by default) doubled on each try, and never more than
      `max_wait` milliseconds (ten seconds by default). A write (`post`, `put`, `patch`, `delete`) is tried again only when the provider takes
      an idempotency key, so a payment is never made twice.
    * **One idempotency key per call.** When `idempotency_header` is set, a write carries the key in
      that header: `idempotency_key` when the caller gives one (derived from its own operation, so a
      repeated call is the same call), a random one otherwise. Every retry sends the same key.
    * **Telemetry.** `[:mishka_pay, :request, :start | :stop | :exception]`, with `:provider`,
      `:method`, `:path` and `:idempotency_key`, and `:status` on `:stop`. Never a key or a body.

  `request/1` answers `{:ok, %Req.Response{}}` for any HTTP status: the adapter reads its
  provider's own error body. A request that never got an answer is a
  `MishkaPay.Errors.Unreachable` error, and a description that is not valid an `:invalid` one.
  `inspect/1` leaves out `:auth`.

  `base_url` is an `http` or `https` address with no user, query or fragment, and `path` one plain
  path from `/`: no query (`params` carries it), no control character, dot segment or encoded
  slash. So a path can never send the request, and its auth, to another host or place.
  `form` and `json` are one or the other. Header names are compared without case.

  `:options` takes any other Req option, such as `plug: {Req.Test, MyTest}` in a test, on top of
  `config :mishka_pay, req_options: [...]` (see `MishkaPay.Test.stub_http/1`). It cannot
  change what this module decides: the method, address, headers, auth, body, retries and timeout.
  """

  use GuardedStruct

  alias MishkaPay.Errors
  alias MishkaPay.Helpers.Required

  @derive {Inspect, only: [:provider, :method, :base_url, :path]}

  @writes [:post, :put, :patch, :delete]
  @retry_statuses [408, 429, 500, 502, 503, 504]

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :one_body} do
    field :provider, String.t(),
      enforce: true,
      derives: "validate(string, not_empty)",
      validator: {Required, :call}

    field :method, :get | :post | :put | :patch | :delete,
      default: :get,
      derives: "validate(enum=Atom[get::post::put::patch::delete])",
      validator: {Required, :call}

    field :base_url, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(string, not_empty)",
      validator: {__MODULE__, :base_url}

    field :path, String.t(),
      enforce: true,
      derives: "validate(string, not_empty)",
      validator: {__MODULE__, :path}

    field :auth, term()
    field :headers, map(), default: %{}, derives: "validate(map)"

    field :params, term(),
      derives: "validate(either=[map, list])",
      validator: {__MODULE__, :params}

    field :form, term(), derives: "validate(either=[map, list])"
    field :json, term()

    field :idempotency_header, String.t(),
      derives: "sanitize(trim, downcase) validate(string, not_empty)"

    field :idempotency_key, String.t(), derives: "validate(string, not_empty)"
    field :max_retries, non_neg_integer(), default: 2, derives: "validate(integer, min_len=0)"
    field :retry_delay, non_neg_integer(), default: 500, derives: "validate(integer, min_len=0)"
    field :max_wait, non_neg_integer(), default: 10_000, derives: "validate(integer, min_len=0)"

    field :receive_timeout, pos_integer(),
      default: 30_000,
      derives: "validate(integer, min_len=1)"

    field :options, keyword(), default: [], derives: "validate(list)"
  end

  @doc "Sends the request `attrs` describe. See the module doc for what it answers."
  @spec request(map()) :: {:ok, Req.Response.t()} | {:error, Splode.Error.t()}
  def request(attrs) do
    with {:ok, spec} <- Errors.from_builder(builder(attrs)) do
      spec |> with_key() |> send_request()
    end
  end

  defp with_key(%{idempotency_header: header, method: method} = spec)
       when is_binary(header) and method in @writes,
       do: %{spec | idempotency_key: spec.idempotency_key || new_key()}

  defp with_key(spec), do: %{spec | idempotency_key: nil}

  defp new_key, do: "mp_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp send_request(spec) do
    meta = %{
      provider: spec.provider,
      method: spec.method,
      path: spec.path,
      idempotency_key: spec.idempotency_key
    }

    :telemetry.span([:mishka_pay, :request], meta, fn ->
      result = spec |> req() |> Req.request()
      {answer(result, spec), Map.put(meta, :status, status(result))}
    end)
  end

  # The caller's Req options first, then everything this module decides on top, so an option can
  # never turn a retry back on or swap the idempotency key.
  defp req(spec) do
    ours =
      [
        method: spec.method,
        base_url: spec.base_url,
        url: spec.path,
        headers: headers(spec),
        retry: retry(spec),
        max_retries: spec.max_retries,
        retry_log_level: false,
        receive_timeout: spec.receive_timeout
      ]
      |> put_present(:auth, spec.auth)
      |> put_present(:params, spec.params)
      |> put_present(:form, spec.form)
      |> put_present(:json, spec.json)

    :mishka_pay
    |> Application.get_env(:req_options, [])
    |> Keyword.merge(spec.options)
    |> Keyword.drop([:auth, :params, :form, :json, :body, :headers, :retry_delay])
    |> Req.new()
    |> Req.merge(ours)
  end

  defp headers(%{headers: headers} = spec) do
    lowered =
      Map.new(headers, fn {name, value} -> {name |> to_string() |> String.downcase(), value} end)

    case spec.idempotency_key do
      nil -> lowered
      key -> Map.put(lowered, spec.idempotency_header, key)
    end
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  # A read is always safe to send again; a write only with its idempotency key.
  defp retry(%{method: method, idempotency_key: nil}) when method in @writes,
    do: false

  defp retry(%{retry_delay: base, max_wait: most}), do: &retry?(&1, &2, {base, most})

  defp retry?(request, %Req.Response{status: status} = response, waits)
       when status in @retry_statuses,
       do: {:delay, response |> retry_after() |> wait(request, waits)}

  defp retry?(request, %Req.TransportError{}, waits), do: {:delay, wait(nil, request, waits)}
  defp retry?(_request, _answer, _waits), do: false

  defp retry_after(response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} when seconds >= 0 <- Integer.parse(String.trim(value)) do
      seconds * 1000
    else
      _no_whole_seconds -> nil
    end
  end

  defp wait(nil, request, {base, most}),
    do: min(base * Integer.pow(2, Req.Request.get_private(request, :req_retry_count, 0)), most)

  defp wait(asked, _request, {_base, most}), do: min(asked, most)

  @doc false
  def base_url(:base_url, url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        {:ok, :base_url, url}

      _other ->
        {:error, :base_url,
         "The base_url field must be an http or https address, with no user, query or fragment"}
    end
  end

  def base_url(:base_url, url), do: Required.call(:base_url, url)

  # One plain path from the root: no second slash at the start, no query or fragment, no backslash,
  # control character, dot segment or percent-encoded slash.
  @unsafe_path ~r{\A//|[?#\\\x00-\x1f\x7f]|%2f|%5c|(\A|/)\.\.?(/|\z)}i

  @doc false
  def path(:path, "/" <> _rest = path) do
    case Regex.match?(@unsafe_path, path) do
      true ->
        {:error, :path,
         "The path field must be one plain path from the root, with no query, dot segment or encoded slash"}

      false ->
        {:ok, :path, path}
    end
  end

  def path(:path, path) when is_binary(path),
    do: {:error, :path, "The path field must start with /"}

  def path(:path, path), do: Required.call(:path, path)

  @doc false
  def params(:params, params) when is_map(params) or is_list(params) do
    URI.encode_query(params)
    {:ok, :params, params}
  rescue
    _not_encodable in [ArgumentError, Protocol.UndefinedError, FunctionClauseError] ->
      {:error, :params, "The params field must hold plain values only"}
  end

  def params(:params, params), do: {:ok, :params, params}

  @doc false
  def one_body(%{form: form, json: json}) when not is_nil(form) and not is_nil(json),
    do: {:error, %{field: :json, action: :one_body, message: "Send form or json, not both"}}

  def one_body(attrs), do: {:ok, attrs}

  defp answer({:ok, %Req.Response{} = response}, _spec), do: {:ok, response}

  defp answer({:error, exception}, spec),
    do: {:error, Errors.Unreachable.exception(provider: spec.provider, reason: exception)}

  defp status({:ok, %Req.Response{status: status}}), do: status
  defp status(_error), do: nil
end

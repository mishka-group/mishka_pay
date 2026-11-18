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
    * **The provider's own word on a retry.** With `retry_header` set (Stripe's
      `"stripe-should-retry"`), an answer carrying it decides: `true` tries again even a status
      that is not on the list above (a lock held a moment too long), `false` never tries again.
      A write without its idempotency key is still never sent twice.
    * **Why the rate was limited.** With `limit_header` set (Stripe's
      `"stripe-rate-limited-reason"`), its value is the `:rate_limit_reason` of the telemetry
      below, so a site can tell a burst of its own from a limit on one endpoint.
    * **One idempotency key per call.** When `idempotency_header` is set, a write carries the key in
      that header: `idempotency_key` when the caller gives one (derived from its own operation, so a
      repeated call is the same call), a random one otherwise. Every retry sends the same key.
    * **Telemetry.** `[:mishka_pay, :request, :start | :stop | :exception]`, with `:provider`,
      `:method`, `:path` and `:idempotency_key`, and `:status` on `:stop`; and
      `[:mishka_pay, :request, :retry]` before each retry, with the `:wait` in milliseconds, the
      `:attempt`, the `:status` or network `:reason`, the `:retry_after` the provider asked
      for and its `:rate_limit_reason`. `:stop` carries the `:rate_limit_reason` of the last
      answer too (`nil` when it gave none). Never a key or a body.

  `request/1` answers `{:ok, %Req.Response{}}` for any HTTP status: the adapter reads its
  provider's own error body. A request that never got an answer is a
  `MishkaPay.Errors.Unreachable` error, and a description that is not valid an `:invalid` one.
  `inspect/1` leaves out `:auth`. `headers`, `params`, `form` and `json` reach the provider as
  given: their keys are never turned into atoms.

  `base_url` is an `http` or `https` address with no user, query or fragment, and `path` one plain
  path from `/`: no query (`params` carries it), no control character, dot segment or encoded
  slash. So a path can never send the request, and its auth, to another host or place.
  Header names are compared without case.

  The body is one of `form`, `json`, `json_text` or `multipart`. `json_text` is a JSON document
  already encoded, sent byte for byte: for a provider that checks a message it signed against the
  exact bytes it sent, such as PayPal's webhook verification. `multipart` sends `multipart/form-data`, the
  way a file is uploaded: a list of `{name, value}` parts, where a value is a binary, or
  `{binary, filename: "receipt.pdf", content_type: "application/pdf"}` for a file. A value is
  always bytes in memory, never a path or a stream, so a request never reads a file from disk.

  `:options` takes any other Req option, such as `plug: {Req.Test, MyTest}` in a test, on top of
  `config :mishka_pay, req_options: [...]` (see `MishkaPay.Test.stub_http/1`). It cannot
  change what this module decides: the method, address, headers, auth, body, retries and timeout.
  """

  use GuardedStruct

  alias MishkaPay.{Errors, Messages}

  @derive {Inspect, only: [:provider, :method, :base_url, :path]}

  @writes [:post, :put, :patch, :delete]
  @retry_statuses [408, 429, 500, 502, 503, 504]

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :one_body} do
    field :provider, String.t(),
      enforce: true,
      derives: "validate(not_nil_value, string, not_empty)"

    field :method, :get | :post | :put | :patch | :delete,
      default: :get,
      derives: "validate(not_nil_value, enum=Atom[get::post::put::patch::delete])"

    field :base_url, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)",
      validator: {__MODULE__, :base_url}

    field :path, String.t(),
      enforce: true,
      derives: "validate(not_nil_value, string, not_empty)",
      validator: {__MODULE__, :path}

    field :auth, term()
    dynamic_field :headers

    dynamic_field :params,
      type: map() | keyword(),
      default: nil,
      derives: "validate(either=[map, list])",
      validator: {__MODULE__, :params}

    dynamic_field :form,
      type: map() | keyword(),
      default: nil,
      derives: "validate(either=[map, list])"

    dynamic_field :json,
      type: map() | list(),
      default: nil,
      derives: "validate(either=[map, list])"

    field :json_text, String.t(), derives: "validate(string, not_empty)"
    field :multipart, term(), validator: {__MODULE__, :multipart}

    field :idempotency_header, String.t(),
      derives: "sanitize(trim, downcase) validate(string, not_empty)"

    field :idempotency_key, String.t(), derives: "validate(string, not_empty)"

    field :retry_header, String.t(),
      derives: "sanitize(trim, downcase) validate(string, not_empty)"

    field :limit_header, String.t(),
      derives: "sanitize(trim, downcase) validate(string, not_empty)"

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

      {answer(result, spec),
       Map.merge(meta, %{
         status: status(result),
         rate_limit_reason: header(result, spec.limit_header)
       })}
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
      |> put_present(:body, spec.json_text)
      |> put_present(:form_multipart, spec.multipart)

    :mishka_pay
    |> Application.get_env(:req_options, [])
    |> Keyword.merge(spec.options)
    |> Keyword.drop([
      :auth,
      :params,
      :form,
      :json,
      :form_multipart,
      :body,
      :headers,
      :retry_delay
    ])
    |> Req.new()
    |> Req.merge(ours)
  end

  defp headers(%{headers: headers} = spec) do
    lowered =
      Map.new(headers, fn {name, value} -> {name |> to_string() |> String.downcase(), value} end)

    lowered
    |> json_type(spec.json_text)
    |> idempotency(spec)
  end

  defp json_type(headers, nil), do: headers
  defp json_type(headers, _text), do: Map.put(headers, "content-type", "application/json")

  defp idempotency(headers, %{idempotency_key: nil}), do: headers

  defp idempotency(headers, spec),
    do: Map.put(headers, spec.idempotency_header, spec.idempotency_key)

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  # A read is always safe to send again; a write only with its idempotency key.
  defp retry(%{method: method, idempotency_key: nil}) when method in @writes,
    do: false

  defp retry(%{retry_delay: base, max_wait: most} = spec),
    do: &retry?(&1, &2, {base, most, Map.take(spec, [:provider, :method, :path])}, spec)

  # The provider's own answer on a retry wins over the status of a failed request; without one,
  # the status decides. An answer that did not fail is never sent again.
  defp retry?(_request, %Req.Response{status: status}, _waits, _spec) when status < 400,
    do: false

  defp retry?(request, %Req.Response{status: status} = response, waits, spec) do
    case {header({:ok, response}, spec.retry_header), status in @retry_statuses} do
      {"false", _status} -> false
      {told, worth?} when told == "true" or worth? -> answered(request, response, spec, waits)
      _not_worth -> false
    end
  end

  defp retry?(request, %Req.TransportError{reason: reason}, waits, _spec),
    do: delay(request, nil, %{reason: reason}, waits)

  defp retry?(_request, _answer, _waits, _spec), do: false

  defp answered(request, %Req.Response{status: status} = response, spec, waits) do
    cause = %{status: status, rate_limit_reason: header({:ok, response}, spec.limit_header)}
    delay(request, retry_after(response), cause, waits)
  end

  # Announces each retry Req will make, with the wait it was given, so a caller (or a test) sees
  # it without timing anything.
  defp delay(request, asked, cause, {_base, _most, meta} = waits) do
    attempt = Req.Request.get_private(request, :req_retry_count, 0)
    wait = wait(asked, request, waits)

    case attempt < Req.Request.get_option(request, :max_retries, 0) do
      true ->
        :telemetry.execute(
          [:mishka_pay, :request, :retry],
          %{wait: wait},
          meta |> Map.merge(cause) |> Map.merge(%{attempt: attempt + 1, retry_after: asked})
        )

      false ->
        :ok
    end

    {:delay, wait}
  end

  defp retry_after(response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} when seconds >= 0 <- Integer.parse(String.trim(value)) do
      seconds * 1000
    else
      _no_whole_seconds -> nil
    end
  end

  defp wait(nil, request, {base, most, _meta}),
    do: min(base * Integer.pow(2, Req.Request.get_private(request, :req_retry_count, 0)), most)

  defp wait(asked, _request, {_base, most, _meta}), do: min(asked, most)

  @doc false
  def base_url(:base_url, url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        {:ok, :base_url, url}

      _other ->
        {:error, :base_url, Messages.text(:base_url)}
    end
  end

  def base_url(:base_url, url), do: {:ok, :base_url, url}

  # One plain path from the root: no second slash at the start, no query or fragment, no backslash,
  # control character, dot segment or percent-encoded slash.
  @unsafe_path ~r{\A//|[?#\\\x00-\x1f\x7f]|%2f|%5c|(\A|/)\.\.?(/|\z)}i

  @doc false
  def path(:path, "/" <> _rest = path) do
    case Regex.match?(@unsafe_path, path) do
      true ->
        {:error, :path, Messages.text(:path_plain)}

      false ->
        {:ok, :path, path}
    end
  end

  def path(:path, path) when is_binary(path),
    do: {:error, :path, Messages.text(:path_root)}

  def path(:path, path), do: {:ok, :path, path}

  @doc false
  def params(:params, params) when is_map(params) or is_list(params) do
    URI.encode_query(params)
    {:ok, :params, params}
  rescue
    _not_encodable in [ArgumentError, Protocol.UndefinedError, FunctionClauseError] ->
      {:error, :params, Messages.text(:params_plain)}
  end

  def params(:params, params), do: {:ok, :params, params}

  # Parts of names and bytes only: a binary, or a binary with its filename and content type.
  @doc false
  def multipart(:multipart, [_ | _] = parts) do
    case Enum.all?(parts, &part?/1) do
      true -> {:ok, :multipart, parts}
      false -> {:error, :multipart, Messages.text(:multipart_parts)}
    end
  end

  def multipart(:multipart, nil), do: {:ok, :multipart, nil}
  def multipart(:multipart, _other), do: {:error, :multipart, Messages.text(:multipart_parts)}

  defp part?({name, value}) when is_binary(name) or is_atom(name), do: part_value?(value)
  defp part?(_other), do: false

  defp part_value?(value) when is_binary(value), do: true

  defp part_value?({value, opts}) when is_binary(value) and is_list(opts),
    do:
      Enum.all?(opts, fn
        {key, text} when key in [:filename, :content_type] -> is_binary(text)
        _other -> false
      end)

  defp part_value?(_other), do: false

  # One body at most; the second one given is the field in the error.
  @doc false
  def one_body(attrs) do
    case for(
           name <- [:form, :json, :json_text, :multipart],
           not is_nil(Map.get(attrs, name)),
           do: name
         ) do
      [_first, second | _rest] ->
        {:error, %{field: second, action: :one_body, message: Messages.text(:one_body)}}

      _one_or_none ->
        {:ok, attrs}
    end
  end

  defp answer({:ok, %Req.Response{} = response}, _spec), do: {:ok, response}

  defp answer({:error, exception}, spec),
    do: {:error, Errors.Unreachable.exception(provider: spec.provider, reason: exception)}

  defp status({:ok, %Req.Response{status: status}}), do: status
  defp status(_error), do: nil

  # The first value of a provider header this request names, read without case.
  defp header({:ok, %Req.Response{} = response}, name) when is_binary(name) do
    case Req.Response.get_header(response, name) do
      [value | _] -> value |> String.trim() |> String.downcase()
      [] -> nil
    end
  end

  defp header(_answer, _name), do: nil
end

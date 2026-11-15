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
      `max_retries` times (2 by default), waiting what a `Retry-After` header says or a growing
      delay. A write (`post`, `put`, `patch`, `delete`) is tried again only when the provider takes
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

  `:options` takes any other Req option, such as `plug: {Req.Test, MyTest}` in a test.
  """

  use GuardedStruct

  alias MishkaPay.Errors
  alias MishkaPay.Helpers.Required

  @derive {Inspect, only: [:provider, :method, :base_url, :path]}

  @writes [:post, :put, :patch, :delete]
  @retry_statuses [408, 429, 500, 502, 503, 504]

  guardedstruct authorized_fields: true do
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
      validator: {Required, :call}

    field :path, String.t(),
      enforce: true,
      derives: "validate(string, not_empty)",
      validator: {Required, :call}

    field :auth, term()
    field :headers, map(), default: %{}, derives: "validate(map)"
    field :params, term(), derives: "validate(either=[map, list])"
    field :form, term(), derives: "validate(either=[map, list])"
    field :json, term()
    field :idempotency_header, String.t(), derives: "sanitize(trim, downcase) validate(string)"
    field :idempotency_key, String.t(), derives: "validate(string, not_empty)"
    field :max_retries, non_neg_integer(), default: 2, derives: "validate(integer, min_len=0)"

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

  defp req(spec) do
    [
      method: spec.method,
      base_url: spec.base_url,
      url: spec.path,
      headers: key_header(spec),
      retry: retry(spec),
      max_retries: spec.max_retries,
      retry_log_level: false,
      receive_timeout: spec.receive_timeout
    ]
    |> put_present(:auth, spec.auth)
    |> put_present(:params, spec.params)
    |> put_present(:form, spec.form)
    |> put_present(:json, spec.json)
    |> Req.new()
    |> Req.merge(spec.options)
  end

  defp key_header(%{idempotency_key: nil, headers: headers}), do: headers

  defp key_header(%{idempotency_key: key, idempotency_header: header, headers: headers}),
    do: Map.put(headers, header, key)

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  # A read is always safe to send again; a write only with its idempotency key.
  defp retry(%{method: method, idempotency_key: nil}) when method in @writes,
    do: false

  defp retry(_spec), do: &retry?/2

  defp retry?(_request, %Req.Response{status: status}), do: status in @retry_statuses
  defp retry?(_request, %Req.TransportError{}), do: true
  defp retry?(_request, _other), do: false

  defp answer({:ok, %Req.Response{} = response}, _spec), do: {:ok, response}

  defp answer({:error, exception}, spec),
    do: {:error, Errors.Unreachable.exception(provider: spec.provider, reason: exception)}

  defp status({:ok, %Req.Response{status: status}}), do: status
  defp status(_error), do: nil
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.RawRequest do
  @moduledoc """
  One call to a provider's own API that Mishka Pay has no typed call for yet, sent with
  `MishkaPay.request/1`. A guarded_struct.

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:method`: `:get` (the default), `:post`, `:put`, `:patch` or `:delete`.
    * `:path`: the provider's API path from the root, such as `"/v1/balance"` at Stripe or
      `"/v2/checkout/orders/5O190127TN364715T"` at PayPal: one plain path, never an address. A
      scheme or host (`"https://evil.test/x"`, `"//evil.test"`), a dot segment (`".."`), a
      query, a backslash, a control character or an encoded slash is refused before any request,
      so a call can never take the tenant's keys to another host or place.
    * `:params`: a map or a keyword list, nested as the provider takes it: the query of a `:get`,
      the body of a write (Stripe's form encoding, `%{"metadata" => %{"a" => "b"}}` as
      `metadata[a]=b`; PayPal's JSON).
    * `:reference`: the caller's own id for a write. With the method and path it makes the
      idempotency key, so the same call sent again is one call at the provider; without it, a
      write gets a fresh key that each of its retries reuses.
    * `:options`: a `MishkaPay.RequestOptions`: another API version and the objects to expand.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :method, :get | :post | :put | :patch | :delete,
      default: :get,
      derives: "validate(not_nil_value, enum=Atom[get::post::put::patch::delete])",
      validator: {__MODULE__, :method}

    field :path, String.t(),
      enforce: true,
      derives: "validate(not_nil_value, string, not_empty)",
      validator: {MishkaPay.Client, :path}

    field :params, term(), derives: "validate(either=[map, list])"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    field :options, struct(), struct: MishkaPay.RequestOptions
  end

  @doc """
  The idempotency key of `call`: its reference with its method and path, so the same reference
  on another path is another call. `nil` without a reference.
  """
  @spec idempotency_key(t()) :: String.t() | nil
  def idempotency_key(%__MODULE__{reference: nil}), do: nil

  def idempotency_key(%__MODULE__{} = call),
    do:
      MishkaPay.ProviderKit.idempotency_key(
        "raw",
        call.tenant,
        {call.method, call.path, call.reference}
      )

  @doc false
  def method(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(get post put patch delete)a)
end

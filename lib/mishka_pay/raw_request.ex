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
      `metadata[a]=b`; PayPal's JSON). They reach the provider as given: their keys are never
      turned into atoms.
    * `:reference`: the caller's own id for a write. With the method and path it makes the
      idempotency key, so the same call sent again is one call at the provider; without it, a
      write gets a fresh key that each of its retries reuses.
    * `:options`: a `MishkaPay.RawRequest.Options`: another API version and the objects to expand.

  ## Options

  `:options` is a `MishkaPay.RawRequest.Options`, a sub_field of this struct: what the request
  asks of the provider beyond its path and params.

    * `:api_version`: the provider's API version to answer in, in place of the one its adapter
      pins (Stripe: `"2026-10-28.endive"`, sent as `Stripe-Version`). Letters, digits, `.`, `-`
      and `_` only.
    * `:expand`: the related objects to send whole instead of by id, each a dotted path such as
      `"customer"` or `"data.latest_charge"`, at most four levels deep (Stripe's limit), up to 20.

  They are only ever turned into the provider's own version header and `expand` params: there is
  no field for a header, so a request option can never change the auth or the idempotency key.
  A provider that has no such thing refuses an option it cannot send, before any request.

  The typed calls (`MishkaPay.fetch_payment/3` and the rest) take none of them: each reads the
  answer in the version its adapter pins, and a struct has no field for an object it did not
  ask for.
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

    dynamic_field :params,
      type: map() | keyword(),
      default: nil,
      derives: "validate(either=[map, list])"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    sub_field :options, MishkaPay.RawRequest.Options.t(), authorized_fields: true do
      field :api_version, String.t(),
        derives:
          ~S"sanitize(trim) validate(string, not_empty, max_len=40, regex=\A[A-Za-z0-9._-]+\z)"

      field :expand, list(),
        derives:
          ~S"validate(list, max_len=20, each=[string, regex=\A[a-z0-9_]+(\.[a-z0-9_]+){0,3}\z])"
    end
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

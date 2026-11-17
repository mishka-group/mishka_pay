# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.RequestOptions do
  @moduledoc """
  What one request asks of the provider beyond its path and params. A guarded_struct.

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
    field :api_version, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=40)",
      validator: {__MODULE__, :api_version}

    field :expand, list(), derives: "validate(list)", validator: {__MODULE__, :expand}
  end

  @doc false
  def api_version(field, version) when is_binary(version) do
    case Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, version) do
      true -> {:ok, field, version}
      false -> {:error, field, MishkaPay.Messages.text(:api_version)}
    end
  end

  def api_version(field, version), do: {:ok, field, version}

  @doc false
  def expand(field, paths) when is_list(paths) do
    case Enum.count_until(paths, 21) <= 20 and Enum.all?(paths, &path?/1) do
      true -> {:ok, field, paths}
      false -> {:error, field, MishkaPay.Messages.text(:expand_paths)}
    end
  end

  def expand(field, paths), do: {:ok, field, paths}

  defp path?(path) when is_binary(path),
    do: Regex.match?(~r/\A[a-z0-9_]+(\.[a-z0-9_]+){0,3}\z/, path)

  defp path?(_not_text), do: false
end

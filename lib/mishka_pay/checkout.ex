# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Checkout do
  @moduledoc """
  A checkout: what the buyer pays for and where they come back to, then the provider's answer. A
  guarded_struct; `MishkaPay.checkout/1` builds it from a map and hands it to the provider.

  What the caller gives:

    * `:provider` and `:tenant`: which provider, with whose keys (`MishkaPay.Credentials`).
    * `:items`: one or more `MishkaPay.Price`, all in one currency.
    * `:success_url`, `:cancel_url`: where the buyer is sent after paying or giving up; `https`, or
      `http` on `localhost`.
    * `:customer`: an optional `MishkaPay.Customer`.
    * `:reference`: the caller's own id for this sale, such as an order id. The provider keeps it,
      it comes back on the payment, and it makes the request's idempotency key, so the same
      reference never opens two checkouts.
    * `:metadata`: up to the provider's limits of extra string pairs.

  What the provider fills in:

    * `:id`: the provider's id of the checkout (`cs_...` at Stripe).
    * `:url`: the page to send the buyer to.
    * `:status`: `:open`, `:complete` or `:expired`.
    * `:payment_id`: the payment it made, once there is one.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :one_currency} do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()
    field :items, list(), enforce: true, structs: MishkaPay.Price

    field :success_url, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string)",
      validator: {__MODULE__, :return_url}

    field :cancel_url, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string)",
      validator: {__MODULE__, :return_url}

    field :customer, struct(), struct: MishkaPay.Customer

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    dynamic_field :metadata

    field :id, String.t(), derives: "validate(string)"
    field :url, String.t(), derives: "validate(string)"

    field :status, :open | :complete | :expired,
      derives: "validate(enum=Atom[open::complete::expired])"

    field :payment_id, String.t(), derives: "validate(string)"
  end

  @doc false
  def return_url(field, url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: "https", host: host} when host not in [nil, ""] -> {:ok, field, url}
      %URI{scheme: "http", host: "localhost"} -> {:ok, field, url}
      _other -> {:error, field, "The #{field} field must be an https address"}
    end
  end

  def return_url(field, url), do: {:ok, field, url}

  # Runs before the items are built, so an item's amount may still be a map from JSON. An items
  # list that failed to build is already reported on its own.
  @doc false
  def one_currency(%{items: []}),
    do: {:error, %{field: :items, action: :items, message: "A checkout needs at least one item"}}

  def one_currency(%{items: items} = attrs) when is_list(items) do
    case items |> MapSet.new(&currency/1) |> MapSet.delete(nil) |> MapSet.size() do
      count when count <= 1 ->
        {:ok, attrs}

      _many ->
        {:error,
         %{field: :items, action: :currency, message: "All items must be in one currency"}}
    end
  end

  def one_currency(attrs), do: {:ok, attrs}

  # The item's money read the way MishkaPay.Money reads it; an item it refuses is reported by the
  # item itself.
  defp currency(%{amount: amount}) do
    case MishkaPay.Money.field(:amount, amount) do
      {:ok, :amount, %Money{currency: currency}} -> currency
      _no_money -> nil
    end
  end

  defp currency(_known_price), do: nil
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Price do
  @moduledoc """
  One line of a checkout: what the buyer pays for, how much and how many. A guarded_struct.

    * `:name`: what the buyer sees, such as "Elixir ebook".
    * `:amount`: the price of one, a `Money` checked by `MishkaPay.Money` (`%{amount: "19.99",
      currency: "USD"}` works too).
    * `:quantity`: 1 by default.
    * `:id`: the provider's own id of a price it already knows (`price_...` at Stripe). With it,
      the provider's price is used and `:name` and `:amount` may be left out.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :named_or_known} do
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :name, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=250)"
    field :amount, Money.t(), validator: {MishkaPay.Money, :field}

    field :quantity, pos_integer(),
      default: 1,
      derives: "validate(not_nil_value, integer, min_len=1)"
  end

  @doc false
  def named_or_known(%{id: id} = attrs) when is_binary(id), do: {:ok, attrs}

  def named_or_known(%{name: name, amount: %Money{}} = attrs) when is_binary(name),
    do: {:ok, attrs}

  def named_or_known(_attrs) do
    {:error,
     %{
       field: :amount,
       action: :price,
       message: MishkaPay.Messages.text(:price_needs)
     }}
  end
end

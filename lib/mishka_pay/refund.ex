# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Refund do
  @moduledoc """
  Money given back on a payment, in full or in part, made with `MishkaPay.refund/1`. A
  guarded_struct.

  A payment is refunded once. After its refund, another one on it is refused
  (`:already_refunded`); a buyer who wants it again makes a new purchase, a new payment. The
  refund's idempotency key comes from the payment, so a refund sent again after a lost answer is
  the same refund, never a second one.

  What the caller gives:

    * `:provider`, `:tenant`: as for a checkout.
    * `:payment_id`: the payment to refund.
    * `:amount`: how much, a `Money`; left out, the whole payment.
    * `:reason`: `:requested_by_customer`, `:duplicate` or `:fraudulent`.

  What the provider fills in: `:id`, `:status` (`:pending`, `:succeeded`, `:failed`, `:canceled`,
  `:requires_action`) and `:created_at`, and `:amount` when it was left out.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :payment_id, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :amount, Money.t(), validator: {__MODULE__, :amount}

    field :reason, atom(),
      derives: "validate(enum=Atom[requested_by_customer::duplicate::fraudulent])"

    field :id, String.t(), derives: "validate(string)"

    field :status, atom(),
      derives: "validate(enum=Atom[pending::succeeded::failed::canceled::requires_action])"

    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  # A refund of nothing is no refund; an amount left out is the whole payment.
  @doc false
  def amount(:amount, value), do: :amount |> MishkaPay.Money.field(value) |> positive()

  defp positive({:ok, :amount, %Money{amount: amount}} = ok) do
    case Decimal.gt?(amount, 0) do
      true -> ok
      false -> {:error, :amount, MishkaPay.Messages.text(:amount_not_positive)}
    end
  end

  defp positive(other), do: other
end

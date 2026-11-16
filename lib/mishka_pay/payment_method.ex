# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.PaymentMethod do
  @moduledoc """
  A payment method a customer saved at the provider (`pm_...` at Stripe), such as a card, so a
  later invoice or subscription charges it without the buyer typing it again. A guarded_struct
  the provider fills in.

  A checkout in `mode: :setup` saves one (`MishkaPay.Checkout`). Read with
  `MishkaPay.fetch_payment_method/3` and `MishkaPay.list_payment_methods/3`, made the customer's
  default with `MishkaPay.set_default_payment_method/4`, and taken off the customer with
  `MishkaPay.detach_payment_method/3`.

    * `:provider`: which provider keeps it.
    * `:id`: the provider's id of the payment method.
    * `:customer_id`: the customer it is saved on; `nil` once it is taken off.
    * `:type`: the provider's kind of payment method, such as `"card"` or `"sepa_debit"`.
    * `:card_brand`, `:card_last4`, `:card_exp_month`, `:card_exp_year`: for a card, its brand
      (`"visa"`), its last four digits and when it expires; `nil` for other kinds.
    * `:created_at`: when it was saved.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "validate(string, not_empty)"
    field :id, String.t(), derives: "validate(string, not_empty)"
    field :customer_id, String.t(), derives: "validate(string)"
    field :type, String.t(), derives: "validate(string)"
    field :card_brand, String.t(), derives: "validate(string)"
    field :card_last4, String.t(), derives: "validate(string)"
    field :card_exp_month, pos_integer(), derives: "validate(integer)"
    field :card_exp_year, pos_integer(), derives: "validate(integer)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

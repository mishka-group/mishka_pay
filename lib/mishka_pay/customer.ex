# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Customer do
  @moduledoc """
  A buyer the provider keeps (`cus_...` at Stripe): who they are, so a returning buyer pays without
  typing their details again and their payments, invoices and subscriptions hang off one record. A
  guarded_struct.

  Made with `MishkaPay.create_customer/1`, changed with `MishkaPay.update_customer/1`, read with
  `MishkaPay.fetch_customer/3` and `MishkaPay.list_customers/3`. A host keeps the customer's `:id`
  on its own user or account.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:email`, `:name`, `:phone`: the buyer's details.
    * `:reference`: the host's own id for the buyer (a user id); it makes the idempotency key, so
      the same reference never makes two customers, and it comes back on the customer.
    * `:metadata`: extra pairs, string keys to string values.

  What the provider fills in: `:id`, `:default_payment_method` (the card future invoices are paid
  with), `:created_at`.

  In a checkout, `customer: %{id: "cus_..."}` sells to a known customer and `customer: %{email:
  "..."}` fills in the email for a new buyer: one or the other (`MishkaPay.Checkout`).
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :email, String.t(), derives: "sanitize(trim, downcase) validate(string, email_r)"
    field :name, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=250)"
    field :phone, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=30)"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
    field :default_payment_method, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

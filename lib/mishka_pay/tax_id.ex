# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.TaxId do
  @moduledoc """
  A business buyer's tax id kept on a provider customer (`txi_...` at Stripe), such as an EU VAT
  number. The provider prints it on the customer's invoices, and a provider that counts the tax
  (Stripe Tax) may then charge no VAT and note a reverse charge. A guarded_struct.

  Added with `MishkaPay.create_tax_id/4`, listed with `MishkaPay.list_tax_ids/4` and removed with
  `MishkaPay.delete_tax_id/4`.

  What the caller gives:

    * `:type`: the provider's kind of tax id, such as `"eu_vat"`, `"gb_vat"`, `"au_abn"` or
      `"us_ein"` (Stripe lists them all at docs.stripe.com/billing/customer/tax-ids).
    * `:value`: the number itself, such as `"DE123456789"`.

  What the provider fills in:

    * `:id`, `:customer_id`, `:created_at`.
    * `:country`: the two-letter country the tax id belongs to.
    * `:verification`: `:pending`, `:verified`, `:unverified` or `:unavailable`, for the kinds a
      provider checks against a government register (EU VAT, GB VAT and AU ABN at Stripe); `nil`
      for the others, whose format alone is checked. A check runs after the tax id is added: the
      provider sends `customer.tax_id.updated` when it ends.
    * `:verified_name`, `:verified_address`: what the register holds for the number.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :tenant, term()
    field :id, String.t(), derives: "validate(string)"
    field :customer_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"

    field :type, String.t(),
      derives:
        "sanitize(trim, downcase) validate(string, not_empty, max_len=20, regex=^[a-z][a-z_]*$)"

    field :value, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=100)"
    field :country, String.t(), derives: "validate(string)"

    field :verification, :pending | :verified | :unverified | :unavailable,
      derives: "validate(enum=Atom[pending::verified::unverified::unavailable])"

    field :verified_name, String.t(), derives: "validate(string)"
    field :verified_address, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

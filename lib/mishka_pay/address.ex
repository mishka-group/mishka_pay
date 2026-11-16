# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Address do
  @moduledoc """
  A postal address: where a buyer lives for the tax (`MishkaPay.TaxCalculation`), or where a
  checkout ships to (`MishkaPay.Checkout`'s `:shipping_address`). A guarded_struct.

    * `:country`: the two-letter ISO 3166-1 code, such as `"NL"`; the only field a tax
      calculation needs outside the US.
    * `:postal_code`: needed for a US address.
    * `:line1`, `:line2`, `:city`, `:state` (ISO 3166-2 when there is one, such as `"CA"`).
    * `:name`: the person it goes to, on a shipping address.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :country, String.t(),
      derives: "sanitize(trim, upcase) validate(string, regex=^[A-Z]{2}$)"

    field :postal_code, String.t(), derives: "sanitize(trim) validate(string, max_len=20)"
    field :line1, String.t(), derives: "sanitize(trim) validate(string, max_len=200)"
    field :line2, String.t(), derives: "sanitize(trim) validate(string, max_len=200)"
    field :city, String.t(), derives: "sanitize(trim) validate(string, max_len=200)"
    field :state, String.t(), derives: "sanitize(trim) validate(string, max_len=200)"
    field :name, String.t(), derives: "sanitize(trim) validate(string, max_len=250)"
  end
end

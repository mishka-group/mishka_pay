# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.TaxRegistration do
  @moduledoc """
  Where the seller is registered to collect tax (`taxreg_...` at Stripe Tax): a provider that
  counts the tax (automatic tax, `MishkaPay.calculate_tax/1`) charges it only where the seller is
  registered. A guarded_struct, added with `MishkaPay.create_tax_registration/1`, listed with
  `MishkaPay.list_tax_registrations/3` and ended with `MishkaPay.expire_tax_registration/4`. A
  provider never deletes one.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:country` (required): the two-letter country.
    * `:type` (required): the kind of registration, in the provider's words. At Stripe:
      `"standard"` in most countries, `"simplified"` for a seller from abroad where only that
      exists; in the EU also `"oss_union"`, `"oss_non_union"` or `"ioss"`; in the US
      `"state_sales_tax"` and the other state kinds; in Canada `"province_standard"` too.
    * `:state`: the US state or the Canadian province (two letters), where the kind needs one.
    * `:active_from`: when it starts; left out, at once.
    * `:expires_at`: when it ends; left out, never.

  What the provider fills in: `:id`, `:status` (`:active`, `:scheduled` or `:expired`) and
  `:created_at`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()
    field :id, String.t(), derives: "validate(string)"

    field :country, String.t(),
      derives: "sanitize(trim, upcase) validate(string, regex=^[A-Z]{2}$)"

    field :type, String.t(),
      derives:
        "sanitize(trim, downcase) validate(string, not_empty, max_len=50, regex=^[a-z][a-z_]*$)"

    field :state, String.t(), derives: "sanitize(trim, upcase) validate(string, regex=^[A-Z]{2}$)"
    field :active_from, DateTime.t(), derives: "validate(struct)"
    field :expires_at, DateTime.t(), derives: "validate(struct)"

    field :status, :active | :scheduled | :expired,
      derives: "validate(enum=Atom[active::scheduled::expired])"

    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.TaxSettings do
  @moduledoc """
  A site's tax settings at a provider that counts the tax (Stripe Tax): where the business is and
  what a price without its own tax fields counts as. A guarded_struct, read with
  `MishkaPay.fetch_tax_settings/2` and changed with `MishkaPay.update_tax_settings/1`, which sends
  only the fields given.

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:head_office`: where the business is located for tax, a `MishkaPay.Address` (its
      `:country` at least; a US address needs its `:state` and `:postal_code`).
    * `:tax_code`: the tax category of a product that names none (Stripe's `"txcd_10000000"`,
      general electronic services).
    * `:tax_behavior`: what a price that says neither counts as: `:exclusive`, `:inclusive`, or
      `:inferred_by_currency` (inclusive in currencies where prices usually hold the tax).

  What the provider fills in: `:status`, `:active` once the provider can count the tax, else
  `:pending` with the `:missing_fields` it still needs (`"head_office"`...).
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()
    field :head_office, struct(), struct: MishkaPay.Address

    field :tax_code, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=100)"

    field :tax_behavior, :inclusive | :exclusive | :inferred_by_currency,
      derives: "validate(enum=Atom[inclusive::exclusive::inferred_by_currency])",
      validator: {__MODULE__, :tax_behavior}

    field :status, :active | :pending, derives: "validate(enum=Atom[active::pending])"
    field :missing_fields, list(), derives: "validate(list)"

    sub_field :registration, struct(),
      authorized_fields: true,
      doc: """
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
        * `:place_of_supply_scheme`: for a `"standard"` registration, which place of supply scheme
          it follows: `:standard`, `:inbound_goods`, or in an EU country also `:small_seller` (a
          seller under the EU's yearly threshold for selling across borders). Stripe takes it in the
          EU and in the other countries whose standard registration has one
          (`MishkaPay.Providers.Stripe.place_of_supply_schemes/2` says which); a registration of
          any other kind or country refuses it.
        * `:active_from`: when it starts; left out, at once.
        * `:expires_at`: when it ends; left out, never.

      What the provider fills in: `:id`, `:status` (`:active`, `:scheduled` or `:expired`) and
      `:created_at`.
      """ do
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

      field :state, String.t(),
        derives: "sanitize(trim, upcase) validate(string, regex=^[A-Z]{2}$)"

      field :place_of_supply_scheme, :inbound_goods | :small_seller | :standard,
        derives: "validate(enum=Atom[inbound_goods::small_seller::standard])",
        validator: {__MODULE__, :place_of_supply_scheme}

      field :active_from, DateTime.t(), derives: "validate(struct)"
      field :expires_at, DateTime.t(), derives: "validate(struct)"

      field :status, :active | :scheduled | :expired,
        derives: "validate(enum=Atom[active::scheduled::expired])"

      field :created_at, DateTime.t(), derives: "validate(struct)"
    end
  end

  @doc false
  def tax_behavior(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(inclusive exclusive inferred_by_currency)a)

  @doc false
  def place_of_supply_scheme(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(inbound_goods small_seller standard)a)
end

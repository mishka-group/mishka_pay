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
  end

  @doc false
  def tax_behavior(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(inclusive exclusive inferred_by_currency)a)
end

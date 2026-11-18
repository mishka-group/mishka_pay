# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.TaxRate do
  @moduledoc """
  A tax rate the seller sets by hand (`txr_...` at Stripe), such as 19% German VAT: the provider
  adds it to the lines it is put on, without counting the tax itself as Stripe Tax does. A
  guarded_struct, made with `MishkaPay.create_tax_rate/1`, read with `MishkaPay.fetch_tax_rate/3`
  and `MishkaPay.list_tax_rates/3`, and changed with `MishkaPay.update_tax_rate/1`.

  A rate goes on a line by its id: `:tax_rate_ids` of a checkout's item (`MishkaPay.Price`), of an
  invoice item (`MishkaPay.Invoice.Item`), or of a whole draft bill (`MishkaPay.Invoice.Draft`).

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:display_name` (required): what the buyer reads on the bill, such as `"VAT"`.
    * `:percentage` (required): from 0 to 100, an integer, a `Decimal` or a number in a string
      (`"7.25"`); never a float.
    * `:inclusive` (required): `true` when the line's amount already holds the tax (as in much of
      Europe), `false` when the tax is added on top (as in the US).
    * `:country` (two letters), `:state` (ISO 3166-2 without the country, such as `"NY"`),
      `:jurisdiction` (a label for the tax reports and the bill) and `:tax_type`, in the
      provider's words (`"vat"`, `"sales_tax"`, `"gst"`...).
    * `:description`: for the seller only; the buyer never sees it.
    * `:active`: `false` archives the rate: no new line takes it, and the lines that have it keep
      it. A provider never deletes a rate.
    * `:reference`: the caller's own id for it; it makes the idempotency key, so the same
      reference never makes two rates, and it comes back on it.
    * `:metadata`: extra pairs, string keys to string values.

  What the provider fills in: `:id`, `:effective_percentage` (what is charged now, where the rate
  depends on the place) and `:created_at`.

  A change (`:id` given) names only what it changes; a rate's `:percentage` and `:inclusive` never
  change: make a new rate and archive the old one.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"

    field :display_name, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=50)"

    field :percentage, Decimal.t(), validator: {__MODULE__, :percentage}
    field :effective_percentage, Decimal.t(), validator: {__MODULE__, :percentage}
    field :inclusive, boolean(), derives: "validate(boolean)"
    field :active, boolean(), derives: "validate(boolean)"

    field :country, String.t(),
      derives: "sanitize(trim, upcase) validate(string, regex=^[A-Z]{2}$)"

    field :state, String.t(), derives: "sanitize(trim, upcase) validate(string, max_len=10)"

    field :jurisdiction, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=50)"

    field :tax_type, String.t(),
      derives:
        "sanitize(trim, downcase) validate(string, not_empty, max_len=50, regex=^[a-z][a-z_]*$)"

    field :description, String.t(), derives: "sanitize(trim) validate(string, max_len=5000)"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  # An exact number from 0 to 100; a float is refused, as for money.
  @doc false
  def percentage(field, nil), do: {:ok, field, nil}

  def percentage(field, value) do
    with {:ok, ^field, number} <- MishkaPay.Usage.value(field, value),
         decimal = Decimal.new(number),
         false <- Decimal.lt?(decimal, 0) or Decimal.gt?(decimal, 100) do
      {:ok, field, decimal}
    else
      _not_a_percentage -> {:error, field, MishkaPay.Messages.text(:tax_percentage)}
    end
  end
end

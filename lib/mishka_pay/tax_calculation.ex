# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.TaxCalculation do
  @moduledoc """
  The tax on a sale made outside the provider's checkout, counted by the provider (Stripe Tax):
  a site that charges with its own form, or sells on an invoice it makes itself, asks
  `MishkaPay.calculate_tax/1` what tax to add, shows it, charges the total, then reports the sale
  with `MishkaPay.record_tax/4`. A guarded_struct.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:items`: one or more `MishkaPay.TaxCalculation.Items`, all in one currency, at most 100.
    * `:address`: where the buyer is, a `MishkaPay.Address` (its `:country`, and its
      `:postal_code` in the US), with `:address_source` `:billing` (the default) or `:shipping`;
      or `:customer_id`, a provider customer whose saved address and tax ids are used. One or the
      other is needed; given both, the address wins.
    * `:shipping`: what shipping costs, as `Money` in the items' currency; the provider counts its
      tax too.

  What the provider fills in:

    * `:id`: the calculation's id (`taxcalc_...` at Stripe), which `MishkaPay.record_tax/4`
      takes.
    * `:amount_total`: what the buyer pays in all, tax and shipping included.
    * `:tax_amount_exclusive`: the tax added on top of the amounts; `:tax_amount_inclusive`: the
      tax already inside amounts given with `tax_behavior: :inclusive`.
    * `:items`: each line again, with its `:amount_tax`.
    * `:expires_at`: after this the calculation can no longer be recorded.

  A provider counts tax only where the account is set up for it (Stripe Tax: an origin address
  and the places it is registered); elsewhere the tax is zero. An account that never turned the
  tax service on is refused with `MishkaPay.Errors.Rejected`, code `"tax_not_set_up"`.

  ## Items

  Each of `:items` is a `MishkaPay.TaxCalculation.Items`, a sub_field of this struct: one line of
  the sale, what is sold, for how much in all, and the tax the provider counted on it.

  What the caller gives:

    * `:reference`: the caller's own name for the line, such as a SKU or an order line id; one
      per line, unique within the calculation. It comes back on the line and in the provider's
      tax reports.
    * `:amount`: what the whole line costs, the unit price times `:quantity`, as `Money` (or
      `%{amount: "30.00", currency: "EUR"}`).
    * `:quantity`: how many, 1 by default.
    * `:tax_code`: the provider's tax category of what is sold (Stripe's `"txcd_10302000"` for
      an e-book); the provider's default category when left out.
    * `:tax_behavior`: `:exclusive` (the default: tax is added on top) or `:inclusive` (the
      amount already holds it).
    * `:product_id`: a catalog product whose tax category is used when `:tax_code` is left out.

  What the provider fills in: `:id` and `:amount_tax`, the tax on the line.
  """

  use GuardedStruct

  alias MishkaPay.Messages

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :consistent} do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    sub_field :items, [MishkaPay.TaxCalculation.Items.t()],
      structs: true,
      authorized_fields: true,
      derives: "validate(not_nil_value, list)" do
      field :reference, String.t(),
        enforce: true,
        derives: "sanitize(trim) validate(not_nil_value, string, not_empty, max_len=500)"

      field :amount, Money.t(), enforce: true, validator: {MishkaPay.Money, :field}

      field :quantity, pos_integer(),
        default: 1,
        derives: "validate(not_nil_value, integer, min_len=1)"

      field :tax_code, String.t(),
        derives: "sanitize(trim) validate(string, not_empty, max_len=100)"

      field :tax_behavior, :inclusive | :exclusive,
        derives: "validate(enum=Atom[inclusive::exclusive])",
        validator: {MishkaPay.Price, :tax_behavior}

      field :product_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
      field :id, String.t(), derives: "validate(string)"
      field :amount_tax, Money.t(), validator: {MishkaPay.Money, :field}
    end

    field :address, struct(), struct: MishkaPay.Address
    field :customer_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"

    field :address_source, :billing | :shipping,
      default: :billing,
      derives: "validate(not_nil_value, enum=Atom[billing::shipping])",
      validator: {__MODULE__, :address_source}

    field :shipping, Money.t(), validator: {MishkaPay.Money, :field}

    field :id, String.t(), derives: "validate(string)"
    field :amount_total, Money.t(), validator: {MishkaPay.Money, :field}
    field :tax_amount_exclusive, Money.t(), validator: {MishkaPay.Money, :field}
    field :tax_amount_inclusive, Money.t(), validator: {MishkaPay.Money, :field}
    field :expires_at, DateTime.t(), derives: "validate(struct)"

    sub_field :transaction, struct(),
      authorized_fields: true,
      doc: """
      A sale reported to the provider's tax records from a `MishkaPay.TaxCalculation`, with
      `MishkaPay.record_tax/4`: the provider then counts its tax in the site's tax reports and
      filings. A guarded_struct the provider fills in.

        * `:provider`, `:id` (`tax_...` at Stripe).
        * `:reference`: the caller's own id of the sale, such as an order id; one sale per reference.
        * `:calculation_id`: the calculation it was made from.
        * `:customer_id`: the provider customer, when the calculation named one.
        * `:posted_at`: when the tax counts as owed; `:created_at`: when the provider made it.
      """ do
      field :provider, String.t(), derives: "validate(string)"
      field :id, String.t(), derives: "validate(string)"
      field :reference, String.t(), derives: "validate(string)"
      field :calculation_id, String.t(), derives: "validate(string)"
      field :customer_id, String.t(), derives: "validate(string)"
      field :posted_at, DateTime.t(), derives: "validate(struct)"
      field :created_at, DateTime.t(), derives: "validate(struct)"
    end
  end

  @doc false
  def address_source(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(billing shipping)a)

  # Lines in one currency (shipping too), each named once, at most 100; and somewhere to count the
  # tax for. It runs on the caller's map, before the fields are built.
  @doc false
  def consistent(attrs) do
    items = List.wrap(key(attrs, :items))
    references = Enum.map(items, &key(&1, :reference))

    cond do
      items == [] ->
        invalid(:items, :items_empty)

      Enum.count_until(items, 101) > 100 ->
        invalid(:items, :tax_lines_many)

      Enum.uniq(references) != references ->
        invalid(:items, :tax_lines_unique)

      [key(attrs, :shipping) | Enum.map(items, &key(&1, :amount))]
      |> MapSet.new(&currency/1)
      |> MapSet.delete(nil)
      |> MapSet.size() > 1 ->
        invalid(:items, :items_currency)

      is_nil(key(attrs, :address)) and is_nil(key(attrs, :customer_id)) ->
        invalid(:address, :tax_address)

      true ->
        {:ok, attrs}
    end
  end

  defp invalid(field, message),
    do: {:error, %{field: field, action: :tax, message: Messages.text(message)}}

  defp currency(amount) do
    case MishkaPay.Money.field(:amount, amount) do
      {:ok, :amount, %Money{currency: currency}} -> currency
      _no_money -> nil
    end
  end

  defp key(%{} = map, name), do: Map.get(map, name) || Map.get(map, Atom.to_string(name))
  defp key(_not_a_map, _name), do: nil
end

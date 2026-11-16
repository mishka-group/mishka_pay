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
    * `:items`: one or more `MishkaPay.TaxLine`, all in one currency, at most 100.
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
  """

  use GuardedStruct

  alias MishkaPay.Messages

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :consistent} do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :items, list(),
      enforce: true,
      structs: MishkaPay.TaxLine,
      derives: "validate(not_nil_value, list)"

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
  end

  @doc false
  def address_source(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(billing shipping))

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

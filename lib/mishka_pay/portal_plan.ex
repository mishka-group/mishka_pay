# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.PortalPlan do
  @moduledoc """
  A product a buyer may switch their subscription to in the customer portal, with the prices of
  it on offer: one of `MishkaPay.PortalConfiguration`'s `:plans`. A guarded_struct.

    * `:product_id`: the catalog product (`MishkaPay.Product`).
    * `:price_ids`: its recurring prices the buyer may pick, one or more.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :priced} do
    field :product_id, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :price_ids, list(), enforce: true, derives: "validate(not_nil_value, list)"
  end

  # One or more price ids, each a plain string.
  @doc false
  def priced(attrs) do
    case key(attrs, :price_ids) do
      [_ | _] = ids ->
        case Enum.all?(ids, &(is_binary(&1) and &1 != "")) do
          true -> {:ok, attrs}
          false -> needs_prices()
        end

      _none ->
        needs_prices()
    end
  end

  defp key(map, name), do: Map.get(map, name) || Map.get(map, Atom.to_string(name))

  defp needs_prices do
    {:error,
     %{
       field: :price_ids,
       action: :portal_plan,
       message: MishkaPay.Messages.text(:customer_needs, field: :price_ids)
     }}
  end
end

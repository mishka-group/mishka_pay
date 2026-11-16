# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Payment.Money do
    @moduledoc """
    The `:money` calculations of `MishkaPay.Ash.Resource`'s kinds: a stored amount with its
    currency, as `Money`.
    """

    use Ash.Resource.Calculation

    @impl true
    def load(_query, opts, _context), do: [opts[:field], :currency]

    @impl true
    def calculate(records, opts, _context) do
      Enum.map(records, &money(&1.currency, Map.fetch!(&1, opts[:field])))
    end

    # An amount the provider has not given yet (a hold not captured, a bill not counted) is nil.
    defp money(currency, amount) when is_nil(currency) or is_nil(amount), do: nil
    defp money(currency, amount), do: Money.new(currency, amount)
  end
end

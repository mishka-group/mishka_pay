# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Payment.Money do
    @moduledoc "The `:money` calculations of `MishkaPay.Ash.Payment`: a stored amount with its currency, as `Money`."

    use Ash.Resource.Calculation

    @impl true
    def load(_query, opts, _context), do: [opts[:field], :currency]

    @impl true
    def calculate(records, opts, _context) do
      Enum.map(records, fn record ->
        Money.new(record.currency, Map.fetch!(record, opts[:field]))
      end)
    end
  end
end

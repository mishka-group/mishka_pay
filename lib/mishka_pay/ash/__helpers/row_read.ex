# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.RowRead do
    @moduledoc """
    The read-only generic actions of a row, for a site's admin pages: they read the row (with the
    caller's actor and tenant) and ask its provider, writing nothing.

      * a payment's `:refunds`: every refund made on it (`MishkaPay.list_refunds/3`);
      * a subscription's `:upcoming_invoice`: the bill it will make next
        (`MishkaPay.upcoming_invoice/3`);
      * a subscription's `:preview_change`: the bill a plan or quantity change would make
        (`MishkaPay.preview_subscription_change/1`), with the `:change` action's arguments.
    """

    use Ash.Resource.Actions.Implementation

    @impl true
    def run(input, opts, context) do
      with {:ok, row} <- Ash.get(input.resource, input.arguments.id, Ash.Context.to_opts(context)),
           {:ok, answer} <- ask(opts[:read], row, input.arguments) do
        {:ok, answer}
      else
        {:error, %{__exception__: true} = error} -> {:error, MishkaPay.Ash.to_ash_error(error)}
      end
    end

    defp ask(:refunds, row, _arguments) do
      with {:ok, page} <-
             MishkaPay.list_refunds(row.provider, row.tenant,
               payment_id: row.provider_id,
               limit: 100
             ),
           do: {:ok, page.items}
    end

    defp ask(:upcoming_invoice, row, _arguments),
      do: MishkaPay.upcoming_invoice(row.provider, row.provider_id, row.tenant)

    defp ask(:preview_change, row, arguments) do
      arguments
      |> Map.delete(:id)
      |> Map.reject(fn {_name, value} -> is_nil(value) end)
      |> Map.merge(%{
        provider: row.provider,
        tenant: row.tenant,
        subscription_id: row.provider_id
      })
      |> MishkaPay.preview_subscription_change()
    end
  end
end

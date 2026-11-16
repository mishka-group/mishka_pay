# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Customer.Portal do
    @moduledoc """
    The `:portal` action of `MishkaPay.Ash.Customer`: reads the row (with the caller's actor and
    tenant) and opens its provider's customer portal with `MishkaPay.portal_session/1`.
    """

    use Ash.Resource.Actions.Implementation

    @impl true
    def run(input, _opts, context) do
      with {:ok, row} <- Ash.get(input.resource, input.arguments.id, Ash.Context.to_opts(context)),
           {:ok, session} <- MishkaPay.portal_session(session(row, input.arguments)) do
        {:ok, session}
      else
        {:error, %{__exception__: true} = error} -> {:error, MishkaPay.Ash.to_ash_error(error)}
      end
    end

    defp session(row, arguments) do
      %{
        provider: row.provider,
        tenant: row.tenant,
        customer_id: row.provider_id,
        return_url: arguments.return_url,
        configuration: arguments[:configuration]
      }
    end
  end
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Payment.StartCheckout do
    @moduledoc """
    The `:start_checkout` action of the `:payment` kind (`MishkaPay.Ash.Resource`):
    `MishkaPay.checkout/1` with Ash errors, in the action's tenant, with the actor as the
    checkout's owner unless it names one (`MishkaPay.Ash.Owner`).
    """

    use Ash.Resource.Actions.Implementation

    @impl true
    def run(input, _opts, context) do
      checkout =
        input.arguments.checkout
        |> MishkaPay.Ash.Tenant.into(MishkaPay.Ash.Tenant.of(input))
        |> MishkaPay.Ash.Owner.into(context.actor)

      case MishkaPay.checkout(checkout) do
        {:ok, checkout} -> {:ok, checkout}
        {:error, error} -> {:error, MishkaPay.Ash.to_ash_error(error)}
      end
    end
  end
end

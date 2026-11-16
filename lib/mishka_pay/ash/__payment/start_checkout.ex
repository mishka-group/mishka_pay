# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Payment.StartCheckout do
    @moduledoc """
    The `:start_checkout` action of the `:payment` kind (`MishkaPay.Ash.Resource`):
    `MishkaPay.checkout/1` with Ash errors.
    """

    use Ash.Resource.Actions.Implementation

    @impl true
    def run(input, _opts, _context) do
      case MishkaPay.checkout(input.arguments.checkout) do
        {:ok, checkout} -> {:ok, checkout}
        {:error, error} -> {:error, MishkaPay.Ash.to_ash_error(error)}
      end
    end
  end
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash do
    @moduledoc """
    The Ash layer, for projects that use Ash: resource fragments a host adds to resources of its
    own domain and data layer, and the listeners that keep them current. Without Ash none of it
    compiles, and the rest of Mishka Pay works on plain structs.

      * `MishkaPay.Ash.Inbox` stores each checked webhook event once and works it with AshOban;
        `MishkaPay.Ash.Inbox.Listener` fills it from `MishkaPay.Webhook`.
      * `MishkaPay.Ash.Payment` keeps each provider payment, synced from the provider, with
        `:start_checkout` and `:refund` actions; `MishkaPay.Ash.Payment.Listener` syncs the
        payment each inbox event concerns.

    A host owns the tables, the domain, the policies and the notifiers: a fragment brings only the
    attributes, identities, calculations and actions.

    ## Errors

    `to_ash_error/1` turns a `MishkaPay.Errors` error into Ash's own classes, so a form shows it on
    its field: an `:invalid` error becomes `Ash.Error.Changes.InvalidArgument`s at their fields,
    anything else an `Ash.Error.Unknown.UnknownError`. The actions here return them.
    """

    alias MishkaPay.Errors

    @doc "A `MishkaPay.Errors` error (or any Splode error) as Ash errors, one per inner error."
    @spec to_ash_error(Exception.t()) :: [Exception.t()]
    def to_ash_error(error) do
      case Errors.to_class(error) do
        %Errors.Invalid{errors: errors} -> Enum.map(errors, &invalid/1)
        other -> [Ash.Error.Unknown.UnknownError.exception(error: Exception.message(other))]
      end
    end

    defp invalid(error),
      do:
        Ash.Error.Changes.InvalidArgument.exception(
          field: Map.get(error, :field),
          message: Exception.message(error)
        )
  end
end

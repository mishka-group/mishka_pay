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
    its field: an `:invalid` error becomes `Ash.Error.Changes.InvalidArgument`s at their fields
    (for a nested input such as the customer of a checkout, at the inner field that failed, such
    as `:email`), anything else an `Ash.Error.Unknown.UnknownError`. The actions here return them.
    """

    alias MishkaPay.Errors

    @doc "A `MishkaPay.Errors` error (or any Splode error) as Ash errors, one per inner error."
    @spec to_ash_error(Exception.t()) :: [Exception.t()]
    def to_ash_error(error) do
      case Errors.to_class(error) do
        %Errors.Invalid{errors: errors} ->
          errors |> Enum.flat_map(&leaves/1) |> Enum.map(&invalid/1)

        %{errors: errors} ->
          Enum.map(errors, &Ash.Error.Unknown.UnknownError.exception(error: message(&1)))
      end
    end

    @doc """
    The plain words of an error, for a person or a log: the error's own message, without the
    breadcrumbs and stack traces a Splode class adds; a class gives its errors' words, joined.
    """
    @spec message(term()) :: String.t()
    def message(%{errors: [_ | _] = errors}), do: Enum.map_join(errors, "; ", &message/1)

    def message(%{child_errors: [_ | _] = errors}), do: Enum.map_join(errors, "; ", &message/1)

    def message(%{__exception__: true, bread_crumbs: [_ | _]} = error),
      do: message(%{error | bread_crumbs: []})

    def message(%Ash.Error.Unknown.UnknownError{error: inner}) when not is_nil(inner),
      do: message(inner)

    # A provider's own words (its `:message`) are for the log: they can name keys and ids.
    def message(%MishkaPay.Errors.Rejected{} = error), do: Exception.message(error)
    def message(%{__exception__: true, message: text}) when is_binary(text), do: text
    def message(%{__exception__: true, __struct__: module} = error), do: module.message(error)
    def message(text) when is_binary(text), do: text
    def message(other), do: inspect(other)

    # A nested input reports its own failures under it; the person needs the inner ones.
    defp leaves(%{child_errors: [_ | _] = errors}), do: Enum.flat_map(errors, &leaves/1)
    defp leaves(error), do: [error]

    defp invalid(%{field: field} = error) when not is_nil(field),
      do: Ash.Error.Changes.InvalidArgument.exception(field: field, message: message(error))

    defp invalid(error), do: Ash.Error.Changes.InvalidChanges.exception(message: message(error))
  end
end

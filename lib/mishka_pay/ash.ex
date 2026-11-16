# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash do
    @moduledoc """
    The Ash layer, for projects that use Ash: the `MishkaPay.Ash.Resource` extension a host adds
    to resources of its own domain and data layer, and the listeners that keep them current.
    Without Ash none of it compiles, and the rest of Mishka Pay works on plain structs.

        defmodule MyApp.Pay.Payment do
          use Ash.Resource,
            domain: MyApp.Pay,
            data_layer: AshPostgres.DataLayer,
            extensions: [MishkaPay.Ash.Resource]

          mishka_pay do
            kind :payment
          end
        end

    A resource keeps one kind: the webhook `:inbox` (each checked event, worked by AshOban),
    `:payment`, `:subscription`, `:customer` or `:dispute`, each synced from its provider. A host
    owns the tables, the domain, the policies and the notifiers; the extension brings the
    attributes, identities, calculations, actions, code interface and listener. `listeners/1`
    lists the listeners of a domain for the application's children.

    ## Errors

    `to_ash_error/1` turns a `MishkaPay.Errors` error into Ash's own classes, so a form shows it on
    its field: an `:invalid` error becomes `Ash.Error.Changes.InvalidArgument`s at their fields
    (for a nested input such as the customer of a checkout, at the inner field that failed, such
    as `:email`), anything else an `Ash.Error.Unknown.UnknownError`. The actions here return them.
    """

    alias MishkaPay.Errors

    @doc """
    The webhook listeners of a domain's resources (`listen? true` in `MishkaPay.Ash.Resource`), in
    the domain's order, for the application's children:

        children = [MishkaPay.Providers.Stripe, MyApp.Pay.Keys] ++ MishkaPay.Ash.listeners(MyApp.Pay)
    """
    @spec listeners(Ash.Domain.t()) :: [module()]
    def listeners(domain) do
      for resource <- Ash.Domain.Info.resources(domain),
          listener = MishkaPay.Ash.Resource.Info.listener(resource),
          do: listener
    end

    @doc """
    Whether `user` has a subscription in `resource` that gives access now: see
    `MishkaPay.Ash.Subscribed`, which is also the policy check.

        MishkaPay.Ash.subscribed?(MyApp.Pay.Subscription, current_user, tenant: site.id)
    """
    @spec subscribed?(Ash.Resource.t(), term(), keyword()) :: boolean()
    defdelegate subscribed?(resource, user, opts \\ []), to: MishkaPay.Ash.Subscribed

    @doc false
    # The `mishka_pay:<kind>:changed` announcement of a change, after its transaction, unless the
    # resource says `announce? false`.
    @spec announce(Ash.Changeset.t(), keyword(), (Ash.Changeset.t(), term() -> term())) ::
            Ash.Changeset.t()
    def announce(changeset, opts, announce) do
      case Keyword.get(opts, :announce?, true) do
        true -> Ash.Changeset.after_transaction(changeset, announce)
        false -> changeset
      end
    end

    @doc false
    # A kind's change: `ask` reads or writes the provider before the transaction (`read/2`), and
    # `announce` fires after it unless the resource says `announce? false`.
    @spec provider_change(Ash.Changeset.t(), keyword(), function(), function()) ::
            Ash.Changeset.t()
    def provider_change(changeset, opts, ask, announce) do
      changeset
      |> Ash.Changeset.before_transaction(&read(&1, ask))
      |> announce(opts, announce)
    end

    @doc false
    # A listener's sync of `resource` for an event: the row of object `id` (argument `id_name`), in
    # the event's tenant; the event state with `:failed` set when it could not be written. A sync
    # skipped for a newer read already kept counts as done.
    @spec sync_event(module(), atom(), String.t(), MishkaPay.Event.t(), map()) :: map()
    def sync_event(resource, id_name, id, event, state) do
      tenant = event.tenant && to_string(event.tenant)
      args = %{:provider => event.provider, id_name => id, :tenant => tenant}

      case Ash.create(
             resource,
             args,
             [action: :sync] ++ MishkaPay.Ash.Tenant.opts(resource, tenant)
           ) do
        {:ok, _row} ->
          state

        {:error, error} ->
          case stale?(error) do
            true -> state
            false -> %{state | failed: message(error)}
          end
      end
    end

    @doc false
    # The provider object a sync reads: from a `:sync` create's arguments, or from the row a
    # `:resync` update runs on.
    @spec object_ref(Ash.Changeset.t(), atom()) :: {String.t(), String.t(), String.t() | nil}
    def object_ref(%{action_type: :update, data: row}, _id_argument),
      do: {row.provider, row.provider_id, row.tenant}

    def object_ref(changeset, id_argument) do
      {Ash.Changeset.get_argument(changeset, :provider),
       Ash.Changeset.get_argument(changeset, id_argument), MishkaPay.Ash.Tenant.of(changeset)}
    end

    @doc false
    # Runs `ask` (the provider call of a change) and keeps when it started in `:synced_at`: the
    # moment the provider's word was read. A `:sync` upsert writes over a row only when its read is
    # not older (`stale?/1`), so a slow read that ends after a newer one never wins.
    @spec read(Ash.Changeset.t(), (Ash.Changeset.t() -> Ash.Changeset.t())) :: Ash.Changeset.t()
    def read(changeset, ask) do
      read_at = DateTime.utc_now()

      case ask.(changeset) do
        %{valid?: true} = changeset ->
          Ash.Changeset.force_change_attribute(changeset, :synced_at, read_at)

        refused ->
          refused
      end
    end

    @doc """
    Whether a `:sync` was skipped because the row holds a newer read of the provider: the sync
    succeeded in effect, since what it would write is already older than what is kept.
    """
    @spec stale?(term()) :: boolean()
    def stale?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &stale?/1)
    def stale?(%Ash.Error.Changes.StaleRecord{}), do: true
    def stale?(_error), do: false

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

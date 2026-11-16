# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Resource.ApplyKind do
    @moduledoc """
    The transformer of `MishkaPay.Ash.Resource`: adds the resource's kind
    (`MishkaPay.Ash.Resource.Kinds`) with `Ash.Resource.Builder`, before any transformer of Ash
    and AshOban sees the resource, and skips whatever the host defines itself.

    A wrong setup is a compile error here, where the kind is applied, rather than in a verifier,
    whose errors Spark reports as warnings: an action the kind does not have, an inbox without all
    of its actions, or an inbox in a project without AshOban.
    """

    use Spark.Dsl.Transformer

    alias Ash.Resource.Builder
    alias MishkaPay.Ash.Resource.{Info, Kinds}
    alias Spark.Dsl.Transformer
    alias Spark.Error.DslError

    @compile {:no_warn_undefined, AshOban}

    @impl true
    def before?(_transformer), do: true

    @impl true
    def transform(dsl) do
      module = Transformer.get_persisted(dsl, :module)

      with {:ok, kind} <- kind(dsl, module),
           {:ok, actions} <- actions(dsl, kind, module),
           :ok <- oban(dsl, kind, module) do
        announce? = Info.mishka_pay_announce?(dsl)

        chosen =
          for {name, _type, _opts} = action <- Kinds.actions(kind, announce?: announce?),
              name in actions,
              do: action

        dsl
        |> primary_key()
        |> each(Kinds.attributes(kind), fn dsl, {name, type, opts} ->
          Builder.add_new_attribute(dsl, name, type, opts)
        end)
        |> Builder.add_new_create_timestamp(:inserted_at)
        |> Builder.add_new_update_timestamp(:updated_at)
        |> identity(Kinds.identity(kind))
        |> each(Kinds.calculations(kind), fn dsl, {name, type, calculation} ->
          Builder.add_new_calculation(dsl, name, type, calculation)
        end)
        |> user(Info.mishka_pay_belongs_to_user(dsl))
        |> read()
        |> each(chosen, fn dsl, {name, type, opts} ->
          Builder.add_new_action(dsl, type, name, opts)
        end)
        |> interfaces(Info.mishka_pay_code_interface?(dsl), actions)
        |> trigger(kind, module)
        |> listener(Info.mishka_pay_listen?(dsl), kind, module)
      end
    end

    defp kind(dsl, module) do
      case Info.mishka_pay_kind(dsl) do
        {:ok, kind} ->
          {:ok, kind}

        :error ->
          error(module, [:mishka_pay], """
          #{inspect(module)} uses MishkaPay.Ash.Resource without a kind. Say what it keeps:

              mishka_pay do
                kind :payment
              end
          """)
      end
    end

    defp actions(dsl, kind, module) do
      all = Kinds.action_names(kind)

      case Info.mishka_pay_actions(dsl) do
        :error -> {:ok, all}
        {:ok, actions} -> chosen(kind, actions, all, module)
      end
    end

    defp chosen(kind, actions, all, module) do
      case {actions -- all, all -- actions} do
        {[_ | _] = unknown, _left_out} ->
          error(module, [:mishka_pay, :actions], """
          #{names(unknown)} is not an action of the #{inspect(kind)} kind. Its actions are
          #{names(all)}.
          """)

        {[], [_ | _]} when kind == :inbox ->
          error(module, [:mishka_pay, :actions], """
          An :inbox works only with all of its actions (#{names(all)}): its trigger processes,
          notes errors and fails each event. Leave `actions` out.
          """)

        {[], _left_out} ->
          {:ok, actions}
      end
    end

    defp oban(dsl, :inbox, module) do
      case AshOban in Transformer.get_persisted(dsl, :spark_extensions, []) do
        true ->
          :ok

        false ->
          error(module, [:mishka_pay, :kind], """
          An :inbox works its events with AshOban, which this project does not have. Add
          `{:ash_oban, "~> 0.10"}` to the dependencies.
          """)
      end
    end

    defp oban(_dsl, _kind, _module), do: :ok

    defp primary_key(dsl) do
      case Enum.any?(Ash.Resource.Info.attributes(dsl), & &1.primary_key?) do
        true ->
          {:ok, dsl}

        false ->
          with {:ok, id} <-
                 Transformer.build_entity(
                   Ash.Resource.Dsl,
                   [:attributes],
                   :uuid_v7_primary_key,
                   name: :id
                 ),
               do: {:ok, Transformer.add_entity(dsl, [:attributes], id)}
      end
    end

    defp identity(dsl, {name, fields}), do: Builder.add_new_identity(dsl, name, fields)

    defp user(dsl, :error), do: dsl

    defp user(dsl, {:ok, {resource, opts}}),
      do: user(dsl, resource, Keyword.get(opts, :attribute))

    defp user(dsl, {:ok, resource}), do: user(dsl, resource, nil)

    defp user(dsl, resource, attribute) do
      Builder.add_new_relationship(dsl, :belongs_to, :user, resource,
        source_attribute: attribute || :user_id,
        public?: true
      )
    end

    # The primary read as `defaults [:read]` makes it (Ash builds it, with keyset pagination for
    # the inbox's trigger), unless the host has its own `:read`.
    defp read({:ok, dsl}) do
      defaults = dsl |> Transformer.get_option([:actions], :defaults) |> List.wrap()

      case is_nil(Ash.Resource.Info.action(dsl, :read)) and :read not in defaults do
        true -> {:ok, Transformer.set_option(dsl, [:actions], :defaults, defaults ++ [:read])}
        false -> {:ok, dsl}
      end
    end

    defp read(error), do: error

    defp interfaces(dsl, false, _actions), do: dsl

    defp interfaces(dsl, true, actions) do
      each(dsl, actions, fn dsl, action ->
        Builder.add_new_interface(dsl, Kinds.interface(action), action: action)
      end)
    end

    defp trigger({:ok, dsl}, :inbox, module) do
      case Enum.any?(Transformer.get_entities(dsl, [:oban, :triggers]), &(&1.name == :process)) do
        true ->
          {:ok, dsl}

        false ->
          with {:ok, trigger} <-
                 Transformer.build_entity(
                   AshOban,
                   [:oban, :triggers],
                   :trigger,
                   Kinds.trigger(module)
                 ),
               do: {:ok, Transformer.add_entity(dsl, [:oban, :triggers], trigger, type: :append)}
      end
    end

    defp trigger(result, _kind, _module), do: result

    # sobelow_skip ["DOS.ModuleConcat"]
    defp listener({:ok, dsl}, true, kind, module) do
      listener = Module.concat(module, MishkaPayListener)
      using = Kinds.listener(kind)

      doc =
        "Keeps `#{inspect(module)}` current from the webhooks Mishka Pay checked (`#{inspect(using)}`)."

      {:ok,
       dsl
       |> Transformer.persist(:mishka_pay_listener, listener)
       |> Transformer.eval(
         [],
         quote do
           defmodule unquote(listener) do
             @moduledoc unquote(doc)
             use unquote(using), resource: unquote(module)
           end
         end
       )}
    end

    defp listener(result, _listen?, _kind, _module), do: result

    defp each(dsl, items, add), do: Enum.reduce(items, dsl, &add.(&2, &1))

    defp names(actions), do: Enum.map_join(actions, ", ", &inspect/1)

    defp error(module, path, message),
      do: {:error, DslError.exception(module: module, path: path, message: String.trim(message))}
  end
end

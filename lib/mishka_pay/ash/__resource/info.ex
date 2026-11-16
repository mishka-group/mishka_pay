# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Resource.Info do
    @moduledoc """
    Reads the `mishka_pay` setup of a resource (`MishkaPay.Ash.Resource`): each option as
    `mishka_pay_<option>/1`, such as `mishka_pay_kind/1` and `mishka_pay_listen?/1`, the actions it
    took from its kind, and the listener made for it.
    """

    use Spark.InfoGenerator, extension: MishkaPay.Ash.Resource, sections: [:mishka_pay]

    alias MishkaPay.Ash.Resource.Kinds

    @doc "The actions the resource took from its kind: its `actions` option, else all of them."
    @spec actions(Spark.Dsl.t() | Ash.Resource.t()) :: [atom()]
    def actions(resource) do
      case mishka_pay_actions(resource) do
        {:ok, actions} -> actions
        :error -> Kinds.action_names(mishka_pay_kind!(resource))
      end
    end

    @doc "The webhook listener module made for the resource (`listen? true`), or `nil`."
    @spec listener(Spark.Dsl.t() | Ash.Resource.t()) :: module() | nil
    def listener(resource),
      do: Spark.Dsl.Extension.get_persisted(resource, :mishka_pay_listener)

    @doc "The attribute `belongs_to_user` keeps the user in (`:user_id` unless named), or `nil`."
    @spec user_attribute(Spark.Dsl.t() | Ash.Resource.t()) :: atom() | nil
    def user_attribute(resource) do
      case mishka_pay_belongs_to_user(resource) do
        {:ok, {_user, opts}} -> Keyword.get(opts, :attribute, :user_id)
        {:ok, _user} -> :user_id
        :error -> nil
      end
    end
  end
end

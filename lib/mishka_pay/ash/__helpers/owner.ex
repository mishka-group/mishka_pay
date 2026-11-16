# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Owner do
    @moduledoc """
    How a payment or a subscription row finds its user (`belongs_to_user` of
    `MishkaPay.Ash.Resource`).

    `:start_checkout` names the actor as the checkout's `:owner` (`MishkaPay.Checkout`), unless the
    checkout names one itself. The provider keeps the owner on the payment or the subscription, so
    every sync, from an action or a webhook, writes it into the user attribute again: the
    provider's word, like every other synced field. An owner that is not a user id of the host
    leaves the attribute empty.
    """

    @doc """
    `attrs` (a checkout map) with the actor's primary key as its `:owner`, unless they name one or
    there is no actor.
    """
    @spec into(map(), term()) :: map()
    def into(attrs, nil), do: attrs

    def into(attrs, %resource{} = actor) when is_map(attrs) do
      case Map.has_key?(attrs, :owner) or Map.has_key?(attrs, "owner") or
             not Ash.Resource.Info.resource?(resource) do
        true -> attrs
        false -> with_key(attrs, Ash.Resource.Info.primary_key(resource), actor)
      end
    end

    def into(attrs, _actor), do: attrs

    defp with_key(attrs, [key], actor), do: Map.put(attrs, :owner, to_string(Map.get(actor, key)))
    defp with_key(attrs, _composite_key, _actor), do: attrs

    @doc """
    The changeset with `owner` in the resource's user attribute, cast to its type; empty when the
    resource has no `belongs_to_user`, or when `owner` is not a value of that type.
    """
    @spec write(Ash.Changeset.t(), String.t() | nil) :: Ash.Changeset.t()
    def write(%Ash.Changeset{resource: resource} = changeset, owner) do
      case MishkaPay.Ash.Resource.Info.user_attribute(resource) do
        nil -> changeset
        name -> Ash.Changeset.force_change_attribute(changeset, name, cast(resource, name, owner))
      end
    end

    defp cast(_resource, _name, nil), do: nil

    defp cast(resource, name, owner) do
      attribute = Ash.Resource.Info.attribute(resource, name)

      case Ash.Type.cast_input(attribute.type, owner, attribute.constraints) do
        {:ok, value} -> value
        _not_a_user -> nil
      end
    end
  end
end

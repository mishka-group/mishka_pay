# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Subscribed do
    @moduledoc """
    Whether a user has a subscription that gives access now: a policy check for the host's own
    resources, and `subscribed?/3` for code and templates. Members-only posts and files sold by
    plan are its first use.

        policies do
          policy action(:read_members_post) do
            authorize_if {MishkaPay.Ash.Subscribed, resource: MyApp.Pay.Subscription}
          end

          policy action(:download_pro_file) do
            authorize_if {MishkaPay.Ash.Subscribed,
                          resource: MyApp.Pay.Subscription, product: ["prod_pro", "prod_team"]}
          end
        end

    It reads `resource` (a `kind :subscription` resource with `belongs_to_user`) for a row of the
    user with a status that gives access, in one query each time, so a cancel or a failed renewal
    the webhooks brought counts at once. The row's user comes from the checkout's owner
    (`MishkaPay.Ash.Owner`).

    ## Options

      * `:resource`: the subscription resource. Required.
      * `:price`, `:product`: a provider price or product id, or a list of them; the user needs a
        subscription to one of them. Left out, any subscription counts.
      * `:statuses`: the statuses that give access, `[:active, :trialing]` unless named. A
        trialing row counts until its `trial_end`. Add `:past_due` to keep access while the
        provider retries a failed renewal.
      * `:tenant`: the site, for `subscribed?/3`; the check takes the action's tenant. A resource
        with Ash multitenancy reads in that tenant, any other compares its `:tenant` attribute.

    The check fails closed: no actor, an actor that is not a resource record, or a read that
    fails, and access is refused.
    """

    use Ash.Policy.SimpleCheck

    require Ash.Query
    import Ash.Expr

    @statuses [:active, :trialing]

    @impl Ash.Policy.Check
    def init(opts) do
      with {:ok, resource} <- resource(opts[:resource]),
           :ok <- ids(opts[:price], :price),
           :ok <- ids(opts[:product], :product) do
        {:ok, Keyword.put(opts, :resource, resource)}
      end
    end

    @impl Ash.Policy.Check
    def describe(opts) do
      case {opts[:price], opts[:product]} do
        {nil, nil} -> "actor has a subscription that gives access"
        {nil, product} -> "actor has a subscription to #{Enum.join(List.wrap(product), " or ")}"
        {price, _product} -> "actor has a subscription to #{Enum.join(List.wrap(price), " or ")}"
      end
    end

    @impl Ash.Policy.SimpleCheck
    def match?(nil, _context, _opts), do: false

    def match?(actor, context, opts),
      do: subscribed?(opts[:resource], actor, Keyword.put(opts, :tenant, tenant(context)))

    @doc """
    Whether `user` (a record of the host's user resource, or its id) has a subscription in
    `resource` that gives access now. Takes the options of the check.
    """
    @spec subscribed?(Ash.Resource.t(), term(), keyword()) :: boolean()
    def subscribed?(resource, user, opts \\ []) do
      with attribute when not is_nil(attribute) <-
             MishkaPay.Ash.Resource.Info.user_attribute(resource),
           {:ok, id} <- user_id(user) do
        statuses = Keyword.get(opts, :statuses, @statuses)

        resource
        |> Ash.Query.filter(^ref(attribute) == ^id and status in ^statuses)
        |> Ash.Query.filter(status != :trialing or is_nil(trial_end) or trial_end > now())
        |> among(:price_ids, opts[:price])
        |> among(:product_ids, opts[:product])
        |> in_tenant(opts[:tenant])
        |> Ash.exists(authorize?: false)
        |> case do
          {:ok, found?} -> found?
          {:error, _cannot_read} -> false
        end
      else
        _no_user -> false
      end
    end

    defp among(query, _field, nil), do: query

    defp among(query, field, ids),
      do: Ash.Query.filter(query, intersects(^ref(field), ^List.wrap(ids)))

    defp in_tenant(query, nil), do: query

    defp in_tenant(query, tenant) do
      case Ash.Resource.Info.multitenancy_strategy(query.resource) do
        nil ->
          Ash.Query.filter(
            query,
            tenant == ^to_string(Ash.ToTenant.to_tenant(tenant, query.resource))
          )

        _strategy ->
          Ash.Query.set_tenant(query, tenant)
      end
    end

    defp user_id(%resource{} = user) do
      case Ash.Resource.Info.resource?(resource) && Ash.Resource.Info.primary_key(resource) do
        [key] -> {:ok, Map.get(user, key)}
        _not_one_key -> :error
      end
    end

    defp user_id(nil), do: :error
    defp user_id(id), do: {:ok, id}

    defp tenant(%{subject: %{tenant: tenant}}), do: tenant
    defp tenant(_context), do: nil

    defp resource(resource) when is_atom(resource) and not is_nil(resource) do
      case Ash.Resource.Info.resource?(resource) do
        true -> {:ok, resource}
        false -> {:error, "#{inspect(resource)} is not an Ash resource"}
      end
    end

    defp resource(_none),
      do: {:error, "MishkaPay.Ash.Subscribed needs `resource:`, a `kind :subscription` resource"}

    defp ids(nil, _name), do: :ok
    defp ids(id, _name) when is_binary(id) and id != "", do: :ok

    defp ids([_ | _] = ids, name) do
      case Enum.all?(ids, &(is_binary(&1) and &1 != "")) do
        true -> :ok
        false -> {:error, "#{name}: a list of provider ids, none empty"}
      end
    end

    defp ids(_other, name), do: {:error, "#{name}: a provider id or a list of them"}
  end
end

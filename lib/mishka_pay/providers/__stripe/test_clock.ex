# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.Stripe.TestClock do
  @moduledoc """
  Stripe's test clocks, to see what time does to a subscription in a sandbox: a trial that ends, a
  renewal that is paid or fails, retries that run out. A customer made on a clock lives on its time;
  moving the clock forward makes Stripe run everything that would have happened by then.

      {:ok, clock} = TestClock.create("site-a", name: "renewal test")
      # make a customer with test_clock: clock.id, and a subscription for them
      {:ok, clock} = TestClock.advance("site-a", clock.id, DateTime.add(clock.frozen_time, 32, :day))
      # Stripe moves it on its own servers: read it until `status: :ready`, then read the
      # subscription again (MishkaPay.fetch_subscription/3)

  Only with a site's test keys: keys in `:live` mode, or a `sk_live_` or `rk_live_` key, are
  refused before any request. Each call takes the tenant whose keys to use.
  """

  use GuardedStruct

  alias MishkaPay.{Credentials, Errors, ProviderKit}
  alias MishkaPay.Providers.Stripe

  @statuses %{
    "ready" => :ready,
    "advancing" => :advancing,
    "internal_failure" => :failed
  }

  guardedstruct authorized_fields: true do
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :name, String.t(), derives: "validate(string)"
    field :frozen_time, DateTime.t(), derives: "validate(struct)"

    field :status, :ready | :advancing | :failed,
      derives: "validate(enum=Atom[ready::advancing::failed])"

    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  @doc "Makes a clock frozen at `:at` (now by default), with an optional `:name`."
  @spec create(term(), keyword()) :: {:ok, t()} | {:error, Splode.Error.t()}
  def create(tenant, opts \\ []) do
    at = Keyword.get_lazy(opts, :at, &DateTime.utc_now/0)
    params = %{"frozen_time" => DateTime.to_unix(at), "name" => opts[:name]}
    call(tenant, :post, "/v1/test_helpers/test_clocks", params)
  end

  @doc "Reads clock `id` again: its time and whether it has finished moving (`:ready`)."
  @spec fetch(term(), String.t()) :: {:ok, t()} | {:error, Splode.Error.t()}
  def fetch(tenant, id),
    do: with_id(id, &call(tenant, :get, "/v1/test_helpers/test_clocks/#{&1}", %{}))

  @doc """
  Moves clock `id` forward to `to`. Stripe answers at once with `status: :advancing` and moves it
  on its own servers; read it with `fetch/2` until it is `:ready`.
  """
  @spec advance(term(), String.t(), DateTime.t()) :: {:ok, t()} | {:error, Splode.Error.t()}
  def advance(tenant, id, %DateTime{} = to) do
    with_id(id, fn id ->
      call(tenant, :post, "/v1/test_helpers/test_clocks/#{id}/advance", %{
        "frozen_time" => DateTime.to_unix(to)
      })
    end)
  end

  @doc "The site's clocks, newest first."
  @spec list(term()) :: {:ok, [t()]} | {:error, Splode.Error.t()}
  def list(tenant) do
    with {:ok, keys} <- test_keys(tenant),
         {:ok, %{"data" => clocks}} <-
           Stripe.request(:get, "/v1/test_helpers/test_clocks", [{"limit", "100"}], keys) do
      {:ok, Enum.flat_map(clocks, &clock_or_none/1)}
    end
  end

  @doc "Deletes clock `id`, and with it every customer and subscription on it."
  @spec delete(term(), String.t()) :: :ok | {:error, Splode.Error.t()}
  def delete(tenant, id) do
    with_id(id, fn id ->
      with {:ok, keys} <- test_keys(tenant),
           {:ok, _deleted} <-
             Stripe.request(:delete, "/v1/test_helpers/test_clocks/#{id}", %{}, keys),
           do: :ok
    end)
  end

  defp call(tenant, method, path, params) do
    with {:ok, keys} <- test_keys(tenant),
         {:ok, clock} <- Stripe.request(method, path, params, keys) do
      clock |> attrs() |> builder() |> Errors.from_builder()
    end
  end

  defp clock_or_none(clock) do
    case clock |> attrs() |> builder() do
      {:ok, built} -> [built]
      {:error, _odd} -> []
    end
  end

  defp attrs(clock) do
    %{
      id: clock["id"],
      name: clock["name"],
      frozen_time: clock["frozen_time"] && DateTime.from_unix!(clock["frozen_time"]),
      status: Map.get(@statuses, clock["status"]),
      created_at: clock["created"] && DateTime.from_unix!(clock["created"])
    }
  end

  # A clock exists only in a sandbox: live keys never reach Stripe from here.
  defp test_keys(tenant) do
    with {:ok, keys} <- Credentials.fetch("stripe", tenant) do
      case keys.mode == :live or String.starts_with?(keys.secret_key, ["sk_live_", "rk_live_"]) do
        true ->
          {:error,
           Errors.Unsupported.exception(
             provider: "stripe",
             operation: "test clock with live keys"
           )}

        false ->
          {:ok, keys}
      end
    end
  end

  defp with_id(id, call) do
    case is_binary(id) and Regex.match?(~r/\Aclock_[A-Za-z0-9]+\z/, id) do
      true ->
        call.(id)

      false ->
        ProviderKit.invalid(
          :clock_id,
          MishkaPay.Messages.text(:stripe_id, field: :clock_id, prefix: "clock_")
        )
    end
  end
end

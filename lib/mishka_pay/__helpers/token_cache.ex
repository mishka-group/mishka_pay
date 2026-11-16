# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Helpers.TokenCache do
  @moduledoc """
  Access tokens a provider gets for a site's keys (PayPal's OAuth token), kept until shortly
  before they expire so each call does not ask for a new one. An ETS table read and written by the
  callers themselves; this process only owns it, so no call ever waits on it.

  Two callers that find no token at the same time both ask the provider and both keep theirs:
  each token is valid, and the next caller reads one of them.
  """

  use GenServer

  @table __MODULE__

  # A token is dropped this long before the provider says it expires.
  @margin_seconds 60

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The token kept under `key`, or a new one from `fetch` (`{:ok, token, expires_in_seconds}`),
  kept for next time. An error from `fetch` is answered as it is and nothing is kept.
  """
  @spec get(term(), (-> {:ok, String.t(), pos_integer()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, term()}
  def get(key, fetch) do
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, token, until}] when until > now -> {:ok, token}
      _missing_or_old -> fetch_and_keep(key, fetch, now)
    end
  end

  @doc "Forgets the token under `key`, such as one the provider no longer takes."
  @spec drop(term()) :: true
  def drop(key), do: :ets.delete(@table, key)

  defp fetch_and_keep(key, fetch, now) do
    case fetch.() do
      {:ok, token, expires_in} ->
        :ets.insert(@table, {key, token, now + expires_in - @margin_seconds})
        {:ok, token}

      {:error, _reason} = error ->
        error
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Test.Keys do
  @moduledoc """
  The keys plugin `MishkaPay.Test.put_keys/3` feeds: it answers first (priority 0) with the keys a
  test put for itself, and `nil` otherwise, so the project's own plugins answer the rest.

  The keys live in a public ETS table keyed by the test's pid. A plugin runs in the caller's
  process, so the lookup walks the caller and its `$callers`: a test's own tasks see its keys, and
  async tests never see each other's.
  """

  use MishkaPay.Credentials, priority: 0

  @table __MODULE__

  @doc false
  def new_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      _exists -> @table
    end
  end

  @doc false
  def put(test, provider, tenant, keys), do: :ets.insert(@table, {{test, provider, tenant}, keys})

  @doc false
  def delete(test), do: :ets.match_delete(@table, {{test, :_, :_}, :_})

  @impl MishkaPay.Credentials
  def credentials(provider, tenant) do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
      lookup({pid, provider, tenant}) || lookup({pid, provider, :any})
    end)
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, keys}] -> keys
      [] -> nil
    end
  end
end

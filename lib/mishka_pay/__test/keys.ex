# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Test.Keys do
  @moduledoc """
  The keys `MishkaPay.Test.put_keys/3` feeds. `MishkaPay.Credentials.fetch/3` reads them before
  any keys plugin: a test's own keys answer first, and the project's plugins answer the rest. It is
  a table, not a plugin, so a project's plugin registry holds nothing of the test kit's.

  The keys live in a public ETS table keyed by the test's pid. A plugin runs in the caller's
  process, so the lookup walks the caller and its `$callers`: a test's own tasks see its keys, and
  async tests never see each other's.
  """

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

  @doc false
  @spec credentials(String.t(), term()) :: map() | nil
  def credentials(provider, tenant) do
    case :ets.whereis(@table) do
      :undefined -> nil
      _table -> find(provider, tenant)
    end
  end

  defp find(provider, tenant) do
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

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.UsageRulesTest do
  # The usage rules an LLM agent reads must never name what does not exist.
  use ExUnit.Case, async: true

  @files ["usage-rules.md" | Path.wildcard("usage-rules/*.md")]

  test "every MishkaPay module the rules name exists" do
    for file <- @files,
        [module] <- Regex.scan(~r/MishkaPay(?:\.[A-Z][A-Za-z0-9]*)+/, File.read!(file)),
        uniq: true do
      assert Code.ensure_loaded?(Module.concat([module])),
             "#{file} names #{module}, which does not exist"
    end
  end

  test "every MishkaPay function the rules name with its arity exists" do
    for file <- @files,
        [_call, module, function, arity] <-
          Regex.scan(~r/(MishkaPay(?:\.[A-Z][A-Za-z0-9]*)*)\.([a-z_!?]+)\/(\d)/, File.read!(file)),
        uniq: true do
      module = Module.concat([module])
      Code.ensure_loaded!(module)

      assert function_exported?(module, String.to_atom(function), String.to_integer(arity)),
             "#{file} names #{inspect(module)}.#{function}/#{arity}, which does not exist"
    end
  end

  test "every sub-rule the main rules list is a file" do
    for [_row, path] <-
          Regex.scan(~r/`(usage-rules\/[a-z_-]+\.md)`/, File.read!("usage-rules.md")) do
      assert File.exists?(path), "usage-rules.md lists #{path}, which is missing"
    end
  end
end

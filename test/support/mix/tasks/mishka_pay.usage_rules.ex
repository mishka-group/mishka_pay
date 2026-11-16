# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.MishkaPay.UsageRules do
  @shortdoc "Fails when the usage rules name a module, function or sub-rule that does not exist"

  @moduledoc """
  Checks `usage-rules.md` and `usage-rules/*.md`, the rules an LLM agent reads before it writes
  code with Mishka Pay: every `MishkaPay.*` module they name exists, every `MishkaPay.*.fun/arity`
  they name is exported, and every sub-rule the main file lists is a file.

      mix mishka_pay.usage_rules

  `mix ci` runs it after Credence. It lives in `test/support` with the other checks of this library,
  and `cli/0` in `mix.exs` runs it in the test environment, where the optional Ash layer compiles.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")
    files = ["usage-rules.md" | Path.wildcard("usage-rules/*.md")]

    problems =
      Enum.flat_map(files, &missing_names/1) ++ missing_sub_rules(File.read!("usage-rules.md"))

    case problems do
      [] ->
        Mix.shell().info("Usage rules: #{length(files)} files, every name exists.")

      _found ->
        Mix.raise("Usage rules name what does not exist:\n  " <> Enum.join(problems, "\n  "))
    end
  end

  defp missing_names(file) do
    text = File.read!(file)

    modules =
      for [name] <- Regex.scan(~r/MishkaPay(?:\.[A-Z][A-Za-z0-9]*)+/, text),
          not Code.ensure_loaded?(Module.concat([name])),
          uniq: true,
          do: "#{file}: #{name}"

    functions =
      for [_call, name, function, arity] <-
            Regex.scan(~r/(MishkaPay(?:\.[A-Z][A-Za-z0-9]*)*)\.([a-z_!?]+)\/(\d)/, text),
          not exported?(Module.concat([name]), function, arity),
          uniq: true,
          do: "#{file}: #{name}.#{function}/#{arity}"

    modules ++ functions
  end

  defp exported?(module, function, arity) do
    Code.ensure_loaded?(module) and
      function_exported?(module, String.to_atom(function), String.to_integer(arity))
  end

  defp missing_sub_rules(text) do
    for [_mention, path] <- Regex.scan(~r/`(usage-rules\/[a-z_-]+\.md)`/, text),
        not File.exists?(path),
        uniq: true,
        do: "usage-rules.md lists #{path}"
  end
end

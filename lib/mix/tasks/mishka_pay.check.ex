# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.MishkaPay.Check do
  @shortdoc "Checks a site's payment setup: provider, keys, webhook, Ash listeners and inbox"

  @moduledoc """
  Runs `MishkaPay.Check` for one site and prints each check; fails when one does not pass, for a
  deploy or CI step. The project starts, for its keys plugin and listeners.

      mix mishka_pay.check --tenant site-42 --webhook-url https://shop.test/pay/webhooks/stripe/site-42 --domain MyApp.Pay

  Options: `--provider` (`stripe` by default), `--tenant`, `--webhook-url`, `--domain`.
  """

  use Mix.Task

  @switches [provider: :string, tenant: :string, webhook_url: :string, domain: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    opts = Keyword.update(opts, :domain, nil, &domain!/1)

    results = MishkaPay.Check.run(opts)

    Enum.each(results, fn
      {name, :ok} -> Mix.shell().info("ok    #{name}")
      {name, {:error, reason}} -> Mix.shell().error("fail  #{name}: #{reason}")
    end)

    case MishkaPay.Check.ok?(results) do
      true -> :ok
      false -> Mix.raise("the setup has checks that did not pass")
    end
  end

  # Only a module that exists: a name from the command line never makes an atom.
  defp domain!(name) do
    Module.safe_concat([name])
  rescue
    ArgumentError -> Mix.raise("--domain #{name} is not a module of this project")
  end
end

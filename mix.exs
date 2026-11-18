# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.MixProject do
  use Mix.Project

  @version "0.0.1-alpha.1"
  @source_url "https://github.com/mishka-group/mishka_pay"

  def project do
    [
      app: :mishka_pay,
      name: "Mishka Pay",
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description: description(),
      package: package(),
      homepage_url: "https://mishka.tools/pay",
      source_url: @source_url,
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        extras: [
          "README.md",
          "guides/getting-started.md",
          "guides/webhooks.md",
          "guides/ash.md",
          "guides/multi-tenant.md",
          "guides/testing.md",
          "guides/errors.md",
          "guides/telemetry.md",
          "guides/production.md",
          "documentation/dsls/DSL-MishkaPay.Ash.Resource.md",
          LICENSE: [title: "License"]
        ],
        groups_for_extras: [Guides: ~r/guides\//, DSLs: ~r/documentation\/dsls\//],
        source_url: @source_url
      ],
      # `test/support` is compiled in the test env, where `mix ci` runs dialyzer. It calls `Mix`,
      # `ExUnit` and, from `mix mishka_pay.credence`, Credence; none is in the default PLT.
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :credence],
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  defp description do
    "A payment SDK for Elixir: plugin-based providers, Stripe in full, PayPal included, with or without Ash."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      maintainers: ["Shahryar Tavakkoli"],
      files:
        ~w(lib priv/gettext .formatter.exs mix.exs LICENSE README* guides usage-rules.md usage-rules),
      links: %{
        "Mishka Pay" => "https://mishka.tools/pay",
        "Official document" => "https://mishka.tools/pay/docs",
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md",
        "Sponsor" => "https://github.com/sponsors/mishka-group",
        "Contributors" => "#{@source_url}/graphs/contributors"
      }
    ]
  end

  def cli,
    do: [
      preferred_envs: [ci: :test, "mishka_pay.credence": :test, "mishka_pay.usage_rules": :test]
    ]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {MishkaPay.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Providers, credentials and every extension point are mishka_installer plugins and events.
      mishka_dep(:mishka_installer, "~> 0.1.16"),
      # Every input and every answer of a provider is a guarded_struct (0.1.8: `not_nil_value`
      # refuses nil).
      mishka_dep(:guarded_struct, "~> 0.1.8", override: true),
      # The HTTP client of every provider adapter.
      {:req, "~> 0.7"},
      # The webhook endpoint (`MishkaPay.Webhook`) is a Plug.
      {:plug, "~> 1.20"},
      {:telemetry, "~> 1.4"},
      # Money is ex_money's `Money`: every ISO 4217 currency, its decimal places and cash rounding,
      # and formatting in any language, from CLDR through `localize` (no backend module).
      {:ex_money, "~> 6.3"},
      {:decimal, "~> 3.2"},
      # Every message a person sees goes through `MishkaPay.Messages`, in the `mishka_pay` domain.
      {:gettext, "~> 1.0"},
      # Every error (`MishkaPay.Errors`) is a Splode error, like Ash's and guarded_struct's.
      {:splode, "~> 0.3"},
      # The Ash layer (`MishkaPay.Ash.*`) compiles only when the host has Ash. Without it the SDK
      # works on plain structs.
      {:ash, "~> 3.37", optional: true},
      # The inbox processes each webhook event as an AshOban job, with retries.
      {:ash_oban, "~> 0.10.3", optional: true},
      # `mix igniter.install mishka_pay` sets a host up (`Mix.Tasks.MishkaPay.Install`).
      {:igniter, "~> 0.8", optional: true},
      {:phx_new, "~> 1.8", only: :test, runtime: false},
      # The policy checks of the tests' resources (`MishkaPay.Ash.Subscribed`) need a SAT solver.
      {:simple_sat, "~> 0.1.4", only: :test},
      # The Ash layer's own tests keep their resources in Postgres, as a host does.
      {:ash_postgres, "~> 2.15", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.19", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      # `mix mishka_pay.credence` (test/support/mix/tasks) runs its pattern rules.
      {:credence, "~> 0.8.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # `mix hex.publish` builds the docs with it.
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  # A Mishka package is its sibling checkout `../<name>` when there is one, and its Hex release
  # otherwise. Only a git checkout counts, so the copy Mix fetched into a host's `deps/` never does,
  # and a `hex.*` task (`mix hex.build`, `mix hex.publish`) always takes Hex, as a package must.
  # `override: true` goes with the sibling only, for a package another dependency takes from Hex,
  # such as guarded_struct, which mishka_installer takes from Hex.
  #
  # `branch:` is for a fix that is not on Hex yet: without a sibling the package comes from that
  # branch of its GitHub repo. Remove it once the fix is released; Hex refuses a git dependency.
  defp mishka_dep(name, requirement, opts \\ []) do
    {path_opts, opts} = Keyword.split(opts, [:override])
    {branch, opts} = Keyword.pop(opts, :branch)

    sibling? =
      File.dir?(Path.expand("../#{name}/.git", __DIR__)) and
        not Enum.any?(System.argv(), &String.starts_with?(&1, "hex."))

    case {sibling?, branch} do
      {true, _branch} ->
        {name, [path: "../#{name}"] ++ path_opts ++ opts}

      {false, nil} ->
        {name, requirement, opts}

      {false, branch} ->
        {name, [github: "mishka-group/#{name}", branch: branch] ++ path_opts ++ opts}
    end
  end

  defp aliases do
    [
      # The Ash layer's tests run on a database made from the test resources (mix ash.codegen).
      test: ["ash.setup --quiet", "test"],
      # The DSL page of `MishkaPay.Ash.Resource` is made from its schema, never by hand.
      docs: [
        "spark.formatter --extensions MishkaPay.Ash.Resource",
        "spark.cheat_sheets --extensions MishkaPay.Ash.Resource",
        "docs"
      ],
      ci: [
        # First: after `compile` Mix has pruned the code path and the Hex archive's task is gone.
        "hex.audit",
        "compile --warnings-as-errors",
        "format --check-formatted",
        # Spark makes the DSL's formatter list and its docs page; both must be current.
        "spark.formatter --check --extensions MishkaPay.Ash.Resource",
        "spark.cheat_sheets --check --extensions MishkaPay.Ash.Resource",
        "credo --strict",
        "mishka_pay.credence",
        # The rules an LLM agent reads name only what exists.
        "mishka_pay.usage_rules",
        # Every message of Messages is in priv/gettext/mishka_pay.pot.
        "gettext.extract --check-up-to-date",
        "sobelow --config",
        "deps.audit",
        "dialyzer",
        "ex_dna --max-clones 0",
        "test"
      ]
    ]
  end

  defp elixirc_paths(:test), do: elixirc_paths(:dev) ++ ["test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

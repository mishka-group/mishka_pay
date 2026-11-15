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
      source_url: @source_url,
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        extras: ["README.md", LICENSE: [title: "License"]],
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
    "A payment SDK for Elixir: providers as mishka_installer plugins, Stripe first, usable on its own or inside Ash."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      maintainers: ["Shahryar Tavakkoli"],
      files: ~w(lib .formatter.exs mix.exs LICENSE README*),
      links: %{
        "GitHub" => @source_url,
        "Sponsor" => "https://github.com/sponsors/mishka-group",
        "Contributors" => "#{@source_url}/graphs/contributors"
      }
    ]
  end

  def cli, do: [preferred_envs: [ci: :test, "mishka_pay.credence": :test]]

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
      # Every input and every answer of a provider is a guarded_struct.
      mishka_dep(:guarded_struct, "~> 0.1.7", override: true),
      # The HTTP client of every provider adapter.
      {:req, "~> 0.7"},
      # The webhook endpoint (`MishkaPay.Webhook`) is a Plug.
      {:plug, "~> 1.20"},
      {:telemetry, "~> 1.4"},
      # The Ash layer (`MishkaPay.Ash.*`) compiles only when the host has Ash. Without it the SDK
      # works on plain structs.
      {:ash, "~> 3.37", optional: true},
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
  defp mishka_dep(name, requirement, opts \\ []) do
    {path_opts, opts} = Keyword.split(opts, [:override])

    sibling? =
      File.dir?(Path.expand("../#{name}/.git", __DIR__)) and
        not Enum.any?(System.argv(), &String.starts_with?(&1, "hex."))

    case sibling? do
      true -> {name, [path: "../#{name}"] ++ path_opts ++ opts}
      false -> {name, requirement, opts}
    end
  end

  defp aliases do
    [
      ci: [
        # First: after `compile` Mix has pruned the code path and the Hex archive's task is gone.
        "hex.audit",
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "mishka_pay.credence",
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

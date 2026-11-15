# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.ProviderCase do
  @moduledoc """
  The contract tests every provider passes, ours and a project's own. One line runs them:

      defmodule MyApp.Pay.AcmeTest do
        use MishkaPay.ProviderCase, provider: MyApp.Pay.Acme
      end

  It checks that the module implements every required callback of `MishkaPay.Provider`, that its
  id, label and capabilities are valid, that each capability has its operations, and that once its plugin starts, `MishkaPay.Provider`
  finds it by its id (or lists it, when `offered?/0` keeps it out of the offered ones). Each stage
  of Mishka Pay adds the contract of its operations here, so a provider written today is checked
  against what tomorrow's calls expect.

  It starts plugins, so the module is `async: false`; other `ExUnit.Case` options pass through.
  Write the provider's own tests below the `use` line.
  """

  import ExUnit.Assertions

  alias MishkaPay.Provider

  @doc false
  defmacro __using__(opts) do
    {provider, opts} = Keyword.pop!(opts, :provider)

    quote do
      use ExUnit.Case, unquote(Keyword.put(opts, :async, false))

      @mishka_pay_provider unquote(provider)

      describe "MishkaPay.Provider contract" do
        test "implements every required callback" do
          MishkaPay.ProviderCase.assert_callbacks(@mishka_pay_provider)
        end

        test "declares a valid id, label and capabilities" do
          MishkaPay.ProviderCase.assert_declaration(@mishka_pay_provider)
        end

        test "is found once its plugin starts" do
          MishkaPay.ProviderCase.assert_installed(@mishka_pay_provider)
        end
      end
    end
  end

  @doc false
  def assert_callbacks(provider) do
    assert Code.ensure_loaded?(provider), "#{inspect(provider)} is not a loaded module"

    missing =
      for {name, arity} <-
            Provider.behaviour_info(:callbacks) -- Provider.behaviour_info(:optional_callbacks),
          not function_exported?(provider, name, arity),
          do: "#{name}/#{arity}"

    assert missing == [],
           "#{inspect(provider)} does not implement #{Enum.join(missing, ", ")} of MishkaPay.Provider"
  end

  @doc false
  def assert_declaration(provider) do
    assert_callbacks(provider)
    id = provider.id()

    assert is_binary(id) and id =~ ~r/\A[a-z][a-z0-9_]*\z/,
           "#{inspect(provider)}.id() must be lowercase letters, digits and _, got: #{inspect(id)}"

    assert is_binary(provider.label()) and provider.label() != "",
           "#{inspect(provider)}.label() must be a non-empty string, got: #{inspect(provider.label())}"

    unknown =
      Enum.reject(
        provider.capabilities(),
        &(&1 in [:checkout, :refund, :subscription, :webhook, :return_verify])
      )

    assert unknown == [],
           "#{inspect(provider)} declares unknown capabilities: #{inspect(unknown)}"

    missing =
      for capability <- provider.capabilities(),
          {name, arity} <- Provider.operations(capability),
          not function_exported?(provider, name, arity),
          do: "#{name}/#{arity} (for #{inspect(capability)})"

    assert missing == [],
           "#{inspect(provider)} declares capabilities without #{Enum.join(missing, ", ")}"
  end

  @doc false
  def assert_installed(provider) do
    assert Code.ensure_loaded?(provider) and function_exported?(provider, :child_spec, 1),
           "#{inspect(provider)} is not a plugin: `use MishkaPay.Provider` makes it one"

    MishkaPay.Test.start_plugin!(provider)
    assert provider in Provider.all(), "#{inspect(provider)} started but is not installed"

    case provider in Provider.offered() do
      true -> assert {:ok, ^provider} = Provider.fetch(provider.id())
      false -> refute function_exported?(provider, :offered?, 0) and provider.offered?()
    end
  end
end

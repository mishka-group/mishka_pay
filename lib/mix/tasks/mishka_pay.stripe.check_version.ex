# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.MishkaPay.Stripe.CheckVersion do
  @shortdoc "Says whether Stripe has published an API version newer than the one Mishka Pay pins"

  @moduledoc """
  Compares the Stripe API version every request is pinned to
  (`MishkaPay.Providers.Stripe.version/0`) with the version of Stripe's newest published OpenAPI
  spec (`MishkaPay.Providers.Stripe.latest_version/0`). It fails when they differ, so a scheduled
  CI job notices when Stripe moves; then read https://docs.stripe.com/changelog, move the pin and
  run the tests against Stripe.

      mix mishka_pay.stripe.check_version

  It needs no keys and reads only the first bytes of the spec.
  """

  use Mix.Task

  alias MishkaPay.Providers.Stripe

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    {:ok, _started} = Application.ensure_all_started(:req)

    pinned = Stripe.version()

    case Stripe.latest_version() do
      {:ok, ^pinned} ->
        Mix.shell().info("Stripe API #{pinned}: Mishka Pay is pinned to the newest version.")

      {:ok, latest} ->
        Mix.raise("""
        Stripe has published API #{latest}; Mishka Pay is pinned to #{pinned}.
        Read https://docs.stripe.com/changelog, move the pin and run the tests against Stripe.
        """)

      {:error, error} ->
        Mix.raise("Stripe's spec could not be read: #{Exception.message(error)}")
    end
  end
end

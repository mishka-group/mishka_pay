# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.MishkaPay.Stripe.WebhookEndpoint do
  @shortdoc "Makes or checks a site's Stripe webhook endpoint with the events Mishka Pay acts on"

  @moduledoc """
  Sets a site's webhook endpoint in its Stripe account
  (`MishkaPay.Providers.Stripe.WebhookEndpoint`): makes it with every event Mishka Pay acts on,
  or adds the events it lacks. With `--check` it changes nothing and fails when events are
  missing, for a CI or deploy check. The project starts, for the site's keys.

      mix mishka_pay.stripe.webhook_endpoint --url https://shop.test/pay/webhooks/stripe/site-42 --tenant site-42
      mix mishka_pay.stripe.webhook_endpoint --url https://shop.test/pay/webhooks/stripe --check

  A new endpoint's signing secret is shown once: keep it as the site's `webhook_secret`.
  """

  use Mix.Task

  alias MishkaPay.Providers.Stripe.WebhookEndpoint

  @switches [url: :string, tenant: :string, check: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    url = opts[:url] || Mix.raise("--url is required: the site's webhook address")
    Mix.Task.run("app.start")

    case opts[:check] do
      true -> check(opts[:tenant], url)
      _set -> ensure(opts[:tenant], url)
    end
  end

  defp check(tenant, url) do
    case WebhookEndpoint.check(tenant, url) do
      {:ok, %{endpoint: nil}} ->
        Mix.raise("Stripe has no webhook endpoint at #{url}")

      {:ok, %{missing: []}} ->
        Mix.shell().info("#{url} sends every event Mishka Pay acts on")

      {:ok, %{missing: missing}} ->
        Mix.raise("#{url} does not send: #{Enum.join(missing, ", ")}")

      {:error, error} ->
        Mix.raise(Exception.message(error))
    end
  end

  defp ensure(tenant, url) do
    case WebhookEndpoint.ensure(tenant, url) do
      {:ok, %{secret: "whsec_" <> _ = secret} = endpoint} ->
        Mix.shell().info("""
        made #{endpoint.id} at #{url}
        signing secret (shown once, keep it as the site's webhook_secret): #{secret}
        """)

      {:ok, endpoint} ->
        Mix.shell().info("#{endpoint.id} at #{url} sends every event Mishka Pay acts on")

      {:error, error} ->
        Mix.raise(Exception.message(error))
    end
  end
end

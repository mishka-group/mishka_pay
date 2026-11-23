# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Check do
  @moduledoc ~S"""
  Checks one site's setup before it takes money, the way a deploy or CI step would: each check is
  `{name, :ok | {:error, reason}}`, in order, and `run/1` never raises. `mix mishka_pay.check`
  prints them.

      MishkaPay.Check.run(provider: "stripe", tenant: site.id,
        webhook_url: "https://shop.test/pay/webhooks/stripe/#{site.id}", domain: MyApp.Pay)

  What it checks:

    * `:provider`: the provider is installed and offered (`MishkaPay.Provider.fetch/1`);
    * `:keys`: the site's keys plugin answers keys for it (`MishkaPay.Credentials`);
    * `:keys_accepted`: the provider takes the keys, with one read call
      (`MishkaPay.Provider` `check_keys/1`, when the provider has it);
    * `:webhook_secret`: the keys carry the secret webhooks are checked with;
    * `:webhook_endpoint`: with `webhook_url:`, the provider sends every event Mishka Pay acts on
      to it (`MishkaPay.Providers.Stripe.WebhookEndpoint`, `MishkaPay.Providers.PayPal.WebhookEndpoint`);
    * `:listeners`: with `domain:` (an Ash domain), each of its Mishka Pay listeners is started;
    * `:inbox`: with `domain:`, it has an `:inbox` resource, and Oban runs its queue.
  """

  alias MishkaPay.{Credentials, Provider}

  @type result :: {atom(), :ok | {:error, String.t()}}

  @doc "Runs every check that applies to `opts`, and answers them in order."
  @spec run(keyword()) :: [result()]
  def run(opts) do
    provider = Keyword.get(opts, :provider, "stripe")
    tenant = opts[:tenant]

    with_provider =
      case Provider.fetch(provider) do
        {:ok, module} -> [{:provider, :ok} | keyed(module, provider, tenant, opts)]
        {:error, error} -> [{:provider, {:error, Exception.message(error)}}]
      end

    with_provider ++ ash(opts[:domain])
  end

  @doc "Whether every check of `results` passed."
  @spec ok?([result()]) :: boolean()
  def ok?(results), do: Enum.all?(results, &match?({_name, :ok}, &1))

  defp keyed(module, provider, tenant, opts) do
    case Credentials.fetch(provider, tenant) do
      {:ok, keys} ->
        [
          {:keys, :ok},
          {:keys_accepted, accepted(module, keys)},
          {:webhook_secret, secret(keys)}
        ] ++ endpoint(provider, tenant, opts[:webhook_url])

      {:error, error} ->
        [{:keys, {:error, Exception.message(error)}}]
    end
  end

  defp accepted(module, keys) do
    case function_exported?(module, :check_keys, 1) && module.check_keys(keys) do
      false -> :ok
      :ok -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp secret(keys) do
    case Credentials.webhook_secrets(keys) do
      [] -> {:error, "the keys have no webhook_secret: webhooks cannot be checked"}
      _secrets -> :ok
    end
  end

  defp endpoint(_provider, _tenant, nil), do: []

  defp endpoint("stripe", tenant, url),
    do: endpoint_check(MishkaPay.Providers.Stripe.WebhookEndpoint.check(tenant, url), url)

  defp endpoint("paypal", tenant, url),
    do: endpoint_check(MishkaPay.Providers.PayPal.WebhookEndpoint.check(tenant, url), url)

  defp endpoint(provider, _tenant, _url),
    do: [{:webhook_endpoint, {:error, "#{provider} has no endpoint check"}}]

  defp endpoint_check(checked, url) do
    case checked do
      {:ok, %{endpoint: nil}} ->
        [{:webhook_endpoint, {:error, "no webhook endpoint at #{url}"}}]

      {:ok, %{missing: []}} ->
        [{:webhook_endpoint, :ok}]

      {:ok, %{missing: missing}} ->
        [{:webhook_endpoint, {:error, "#{url} does not send #{Enum.join(missing, ", ")}"}}]

      {:error, error} ->
        [{:webhook_endpoint, {:error, Exception.message(error)}}]
    end
  end

  defp ash(nil), do: []

  defp ash(domain) do
    case Code.ensure_loaded?(MishkaPay.Ash) and Code.ensure_loaded?(domain) do
      true -> [{:listeners, listeners(domain)}, {:inbox, inbox(domain)}]
      false -> [{:listeners, {:error, "#{inspect(domain)} is not an Ash domain here"}}]
    end
  end

  defp listeners(domain) do
    case Enum.reject(MishkaPay.Ash.listeners(domain), &started?/1) do
      [] -> :ok
      idle -> {:error, "not started: #{Enum.map_join(idle, ", ", &inspect/1)}"}
    end
  end

  defp started?(listener) do
    case MishkaInstaller.Event.Event.get(:name, listener) do
      %{status: status} -> status in [:started, :restarted]
      _not_registered -> false
    end
  end

  defp inbox(domain) do
    inboxes =
      for resource <- Ash.Domain.Info.resources(domain),
          MishkaPay.Ash.Resource.Info.mishka_pay_kind(resource) == {:ok, :inbox},
          do: resource

    case {inboxes, queue?()} do
      {[], _queue} -> {:error, "#{inspect(domain)} has no kind :inbox resource"}
      {_inbox, false} -> {:error, "Oban does not run the mishka_pay_inbox queue"}
      {_inbox, true} -> :ok
    end
  end

  defp queue? do
    Code.ensure_loaded?(Oban) and
      match?(%{}, Oban.check_queue(queue: :mishka_pay_inbox))
  catch
    :exit, _not_running -> false
  end
end

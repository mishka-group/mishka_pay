# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.Stripe.WebhookEndpoint do
  @moduledoc """
  A site's webhook endpoint in its Stripe account, set from code instead of the Dashboard, with
  the events Mishka Pay acts on (`MishkaPay.Providers.Stripe.handled_events/0`) and the API version
  it is pinned to. `mix mishka_pay.stripe.webhook_endpoint` runs it.

      {:ok, endpoint} = WebhookEndpoint.ensure("site-42", "https://shop.test/pay/webhooks/stripe/site-42")
      # a new endpoint answers its signing secret once: keep it as the site's `webhook_secret`

      {:ok, %{endpoint: endpoint, missing: []}} = WebhookEndpoint.check("site-42", url)

  `ensure/2` makes the endpoint when the account has none at that URL, or adds the events it
  lacks to the one it has; it never removes events another part of the site may need. `check/2`
  changes nothing and says which events the endpoint at that URL does not send.
  """

  use GuardedStruct

  alias MishkaPay.{Credentials, Errors}
  alias MishkaPay.Providers.Stripe

  guardedstruct authorized_fields: true do
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :url, String.t(), derives: "validate(string)"
    field :enabled_events, list(), default: [], derives: "validate(list)"
    field :status, :enabled | :disabled, derives: "validate(enum=Atom[enabled::disabled])"
    field :api_version, String.t(), derives: "validate(string)"
    field :secret, String.t(), derives: "validate(string)"
  end

  @doc "The endpoint at `url` with every event Mishka Pay acts on: made, or its events added."
  @spec ensure(term(), String.t()) :: {:ok, t()} | {:error, Splode.Error.t()}
  def ensure(tenant, url) when is_binary(url) do
    with {:ok, keys} <- Credentials.fetch("stripe", tenant),
         {:ok, found} <- find(url, keys) do
      case found do
        nil -> create(url, keys)
        endpoint -> add_missing(endpoint, keys)
      end
    end
  end

  @doc """
  The endpoint at `url`, or `nil`, and the events Mishka Pay acts on that it does not send. An
  endpoint that sends every event (`*`) misses none.
  """
  @spec check(term(), String.t()) ::
          {:ok, %{endpoint: t() | nil, missing: [String.t()]}} | {:error, Splode.Error.t()}
  def check(tenant, url) when is_binary(url) do
    with {:ok, keys} <- Credentials.fetch("stripe", tenant),
         {:ok, endpoint} <- find(url, keys) do
      {:ok, %{endpoint: endpoint, missing: missing(endpoint)}}
    end
  end

  @doc "Deletes endpoint `id`: Stripe stops sending to it."
  @spec delete(term(), String.t()) :: :ok | {:error, Splode.Error.t()}
  def delete(tenant, "we_" <> _ = id) do
    with {:ok, keys} <- Credentials.fetch("stripe", tenant),
         {:ok, _deleted} <- Stripe.request(:delete, "/v1/webhook_endpoints/#{id}", %{}, keys),
         do: :ok
  end

  def delete(_tenant, _id),
    do:
      MishkaPay.ProviderKit.invalid(
        :endpoint_id,
        MishkaPay.Messages.text(:stripe_id, field: :endpoint_id, prefix: "we_")
      )

  defp find(url, keys) do
    with {:ok, %{"data" => endpoints}} <-
           Stripe.request(:get, "/v1/webhook_endpoints", [{"limit", "100"}], keys) do
      case Enum.find(endpoints, &(&1["url"] == url)) do
        nil -> {:ok, nil}
        endpoint -> built(endpoint)
      end
    end
  end

  defp create(url, keys) do
    params = %{
      "url" => url,
      "enabled_events" => handled(),
      "api_version" => Stripe.version(),
      "description" => "Mishka Pay"
    }

    with {:ok, endpoint} <- Stripe.request(:post, "/v1/webhook_endpoints", params, keys),
         do: built(endpoint)
  end

  defp add_missing(endpoint, keys) do
    case missing(endpoint) do
      [] ->
        {:ok, endpoint}

      missing ->
        params = %{"enabled_events" => Enum.sort(endpoint.enabled_events ++ missing)}

        with {:ok, updated} <-
               Stripe.request(:post, "/v1/webhook_endpoints/#{endpoint.id}", params, keys),
             do: built(updated)
    end
  end

  defp missing(nil), do: handled()

  defp missing(%__MODULE__{enabled_events: events}) do
    case "*" in events do
      true -> []
      false -> handled() -- events
    end
  end

  defp handled, do: Stripe.handled_events() |> Map.keys() |> Enum.sort()

  defp built(endpoint) do
    %{
      id: endpoint["id"],
      url: endpoint["url"],
      enabled_events: endpoint["enabled_events"] || [],
      status: status(endpoint["status"]),
      api_version: endpoint["api_version"],
      secret: endpoint["secret"]
    }
    |> builder()
    |> Errors.from_builder()
  end

  defp status("enabled"), do: :enabled
  defp status("disabled"), do: :disabled
  defp status(_other), do: nil
end

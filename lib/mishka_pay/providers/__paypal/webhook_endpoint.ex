# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.PayPal.WebhookEndpoint do
  @moduledoc """
  A site's webhook in its PayPal app, set from code instead of PayPal's developer dashboard, with
  the events Mishka Pay acts on (`MishkaPay.Providers.PayPal.handled_events/0`), the PayPal side
  of `MishkaPay.Providers.Stripe.WebhookEndpoint`:

      {:ok, %{id: webhook_id}} = WebhookEndpoint.ensure("site-42", "https://shop.test/pay/webhooks/paypal/site-42")
      # keep webhook_id (WH-...) as the site's `webhook_secret`: PayPal checks each message with it

      {:ok, %{endpoint: endpoint, missing: []}} = WebhookEndpoint.check("site-42", url)

  `ensure/2` makes the webhook when the app has none at that URL, or adds the events it lacks to
  the one it has (PayPal replaces a webhook's event types as a whole: the ones it had are kept);
  it never takes events away. `check/2` changes nothing and says which events the webhook at that
  URL does not send; one that sends every event (`*`) misses none. `delete/2` takes its id. The
  URL is an `https` address (PayPal sends to no other); anything else is refused before any
  request. The site's PayPal keys are read from `MishkaPay.Credentials`, and every request goes
  through the adapter with its OAuth token.
  """

  use GuardedStruct

  alias MishkaPay.Credentials
  alias MishkaPay.Providers.PayPal

  @webhooks "/v1/notifications/webhooks"

  guardedstruct authorized_fields: true do
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :url, String.t(), derives: "validate(string)"
    field :enabled_events, list(), default: [], derives: "validate(list)"
  end

  @doc "The webhook at `url` with every event Mishka Pay acts on: made, or its events added."
  @spec ensure(term(), String.t()) :: {:ok, t()} | {:error, Splode.Error.t()}
  def ensure(tenant, url) when is_binary(url) do
    with {:ok, keys} <- prepare(tenant, url),
         {:ok, found} <- find(url, keys) do
      case found do
        nil -> create(url, keys)
        webhook -> add_missing(webhook, keys)
      end
    end
  end

  @doc """
  The webhook at `url`, or `nil`, and the events Mishka Pay acts on that it does not send.
  """
  @spec check(term(), String.t()) ::
          {:ok, %{endpoint: t() | nil, missing: [String.t()]}} | {:error, Splode.Error.t()}
  def check(tenant, url) when is_binary(url) do
    with {:ok, keys} <- prepare(tenant, url),
         {:ok, webhook} <- find(url, keys) do
      {:ok, %{endpoint: webhook, missing: missing(webhook)}}
    end
  end

  @doc "Deletes webhook `id` (`WH-...`): PayPal stops sending to it."
  @spec delete(term(), String.t()) :: :ok | {:error, Splode.Error.t()}
  def delete(tenant, id) when is_binary(id) do
    with :ok <- webhook_id(id),
         {:ok, keys} <- Credentials.fetch("paypal", tenant),
         {:ok, _deleted} <- PayPal.request(:delete, "#{@webhooks}/#{id}", %{}, keys),
         do: :ok
  end

  defp prepare(tenant, url) do
    with :ok <- address(url), do: Credentials.fetch("paypal", tenant)
  end

  defp address(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      _other -> MishkaPay.ProviderKit.invalid(:url, MishkaPay.Messages.text(:endpoint_url))
    end
  end

  # An app holds at most ten webhooks, all in one answer.
  defp find(url, keys) do
    with {:ok, %{"webhooks" => webhooks}} <- PayPal.request(:get, @webhooks, %{}, keys) do
      case Enum.find(webhooks, &(&1["url"] == url)) do
        nil -> {:ok, nil}
        webhook -> endpoint(webhook)
      end
    end
  end

  defp create(url, keys) do
    body = %{"url" => url, "event_types" => types(PayPal.handled_events())}

    with {:ok, webhook} <-
           PayPal.request(:post, @webhooks, body, keys,
             key: MishkaPay.ProviderKit.idempotency_key("webhook", keys.tenant, url)
           ),
         do: endpoint(webhook)
  end

  defp add_missing(webhook, keys) do
    case missing(webhook) do
      [] ->
        {:ok, webhook}

      missing ->
        patch = [
          %{
            "op" => "replace",
            "path" => "/event_types",
            "value" => types(webhook.enabled_events ++ missing)
          }
        ]

        with {:ok, changed} <-
               PayPal.request(:patch, "#{@webhooks}/#{webhook.id}", patch, keys),
             do: endpoint(changed)
    end
  end

  defp missing(nil), do: PayPal.handled_events()

  defp missing(%{enabled_events: events}) do
    case "*" in events do
      true -> []
      false -> PayPal.handled_events() -- events
    end
  end

  defp types(names), do: Enum.map(names, &%{"name" => &1})

  defp endpoint(webhook) do
    %{
      id: webhook["id"],
      url: webhook["url"],
      enabled_events: Enum.map(webhook["event_types"] || [], & &1["name"])
    }
    |> builder()
    |> MishkaPay.Errors.from_builder()
  end

  defp webhook_id(id) do
    case Regex.match?(~r/\AWH-[A-Z0-9-]{6,60}\z/, id) do
      true -> :ok
      false -> MishkaPay.ProviderKit.invalid(:id, MishkaPay.Messages.text(:paypal_id, field: :id))
    end
  end
end

# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.Stripe.WebhookEndpoint do
  @moduledoc """
  A site's webhook endpoint in its Stripe account, set from code instead of the Dashboard, with
  the events Mishka Pay acts on. `mix mishka_pay.stripe.webhook_endpoint` runs it.

      {:ok, endpoint} = WebhookEndpoint.ensure("site-42", "https://shop.test/pay/webhooks/stripe/site-42")
      # a new endpoint answers its signing secret once: keep it as the site's `webhook_secret`

      {:ok, %{endpoint: endpoint, missing: []}} = WebhookEndpoint.check("site-42", url)

  Two kinds of events, on two APIs, each a developer option: per site in its keys (`:events`,
  `:webhook_api`, `MishkaPay.Credentials`), per call in `opts`:

    * `events: :thin` (the default, the format Stripe recommends): an event destination
      (`/v2/core/event_destinations`) with the thin payload and the thin events Mishka Pay maps
      (`MishkaPay.Providers.Stripe.thin_events/0`). A thin event names its object; the webhook
      reads what it needs and hands listeners the same `MishkaPay.Event` a snapshot event gives.
    * `events: :snapshot`: the events of `MishkaPay.Providers.Stripe.handled_events/0`, each with
      its object as it was, rendered in the pinned API version; on an event destination
      (`api: :v2`, the default) or on Stripe's older `/v1/webhook_endpoints` (`api: :v1`). Thin
      events never go to a `/v1/webhook_endpoints` endpoint: `events: :thin` with `api: :v1` is
      `Errors.Invalid` before any request.
    * `connected_accounts: true`: a platform's destination also takes its connected accounts'
      events (`events_from` `@self` and `@accounts`; on v1, `connect: true`); each names its
      `:account`.

  The URL is an `https` address, or `http` on `localhost`; anything else is refused before any
  request. `ensure/3` makes the endpoint when the account has none of that kind at that URL, or
  adds the events it lacks to the one it has; it never removes events another part of the site
  may need. A thin and a snapshot destination may share a URL while a site moves from one to the
  other: the webhook takes both, each checked with its own secret (keep both in
  `:webhook_secrets` meanwhile). `check/3` changes nothing and says which events the endpoint at
  that URL does not send. `disable/2`, `enable/2` and `delete/2` take its id: `ed_...` for an
  event destination, `we_...` for a v1 endpoint (Stripe lists those among its destinations too).
  """

  use GuardedStruct

  alias MishkaPay.{Credentials, Errors, Page}
  alias MishkaPay.Providers.Stripe

  @destinations "/v2/core/event_destinations"
  @endpoints "/v1/webhook_endpoints"

  guardedstruct authorized_fields: true do
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :url, String.t(), derives: "validate(string)"
    field :enabled_events, list(), default: [], derives: "validate(list)"
    field :status, :enabled | :disabled, derives: "validate(enum=Atom[enabled::disabled])"
    field :events, :thin | :snapshot, derives: "validate(enum=Atom[thin::snapshot])"
    field :api, :v2 | :v1, derives: "validate(enum=Atom[v2::v1])"
    field :events_from, list(), default: [], derives: "validate(list)"
    field :api_version, String.t(), derives: "validate(string)"
    field :secret, String.t(), derives: "validate(string)"
  end

  @doc "The endpoint at `url` with every event Mishka Pay acts on: made, or its events added."
  @spec ensure(term(), String.t(), keyword()) :: {:ok, t()} | {:error, Splode.Error.t()}
  def ensure(tenant, url, opts \\ []) when is_binary(url) do
    with {:ok, keys, setup} <- prepare(tenant, url, opts),
         {:ok, found} <- find(url, setup, keys) do
      case found do
        nil -> create(url, setup, keys)
        endpoint -> add_missing(endpoint, setup, keys)
      end
    end
  end

  @doc """
  The endpoint of the asked kind at `url`, or `nil`, and the events Mishka Pay acts on that it
  does not send. An endpoint that sends every event (`*`) misses none.
  """
  @spec check(term(), String.t(), keyword()) ::
          {:ok, %{endpoint: t() | nil, missing: [String.t()]}} | {:error, Splode.Error.t()}
  def check(tenant, url, opts \\ []) when is_binary(url) do
    with {:ok, keys, setup} <- prepare(tenant, url, opts),
         {:ok, endpoint} <- find(url, setup, keys) do
      {:ok, %{endpoint: endpoint, missing: missing(endpoint, setup)}}
    end
  end

  @doc "Stops Stripe sending to endpoint `id` and keeps it; `enable/2` starts it again."
  @spec disable(term(), String.t()) :: {:ok, t()} | {:error, Splode.Error.t()}
  def disable(tenant, id), do: switch(tenant, id, :disable)

  @doc "Has Stripe send to endpoint `id` again."
  @spec enable(term(), String.t()) :: {:ok, t()} | {:error, Splode.Error.t()}
  def enable(tenant, id), do: switch(tenant, id, :enable)

  @doc "Deletes endpoint `id`: Stripe stops sending to it."
  @spec delete(term(), String.t()) :: :ok | {:error, Splode.Error.t()}
  def delete(tenant, id) do
    with {:ok, api} <- api_of(id),
         {:ok, keys} <- Credentials.fetch("stripe", tenant),
         {:ok, _deleted} <- Stripe.request(:delete, path(api, id), %{}, keys),
         do: :ok
  end

  defp prepare(tenant, url, opts) do
    with :ok <- address(url),
         {:ok, keys} <- Credentials.fetch("stripe", tenant),
         {:ok, events} <- Stripe.events_kind(opts[:events], keys),
         {:ok, api} <- Stripe.choice(:api, opts[:api], :webhook_api, keys, [:v2, :v1]),
         :ok <- thin_on_v2(events, api) do
      {:ok, keys, %{events: events, api: api, accounts: opts[:connected_accounts] == true}}
    end
  end

  defp thin_on_v2(:thin, :v1),
    do: MishkaPay.ProviderKit.invalid(:api, MishkaPay.Messages.text(:thin_needs_v2))

  defp thin_on_v2(_events, _api), do: :ok

  # Stripe sends webhooks to an https address; a local one over http is fine for a sandbox.
  defp address(url) do
    case MishkaPay.Checkout.return_url(:url, url) do
      {:ok, :url, _url} ->
        :ok

      {:error, :url, _message} ->
        MishkaPay.ProviderKit.invalid(:url, MishkaPay.Messages.text(:endpoint_url))
    end
  end

  # Stripe redacts a destination's URL unless asked for it. An account holds at most 16
  # destinations, so one page of 20 is all of them.
  defp find(url, %{api: :v2, events: events}, keys) do
    payload = Atom.to_string(events)
    included = %{"include" => ["webhook_endpoint.url"]}

    with {:ok, destinations} <-
           Page.all(
             &Stripe.v2_page(@destinations, included, &1, keys, fn dest -> {:ok, dest} end)
           ) do
      destinations
      |> Enum.find(
        &match?(%{"event_payload" => ^payload, "webhook_endpoint" => %{"url" => ^url}}, &1)
      )
      |> found()
    end
  end

  defp find(url, %{api: :v1}, keys) do
    with {:ok, %{"data" => endpoints}} <-
           Stripe.request(:get, @endpoints, [{"limit", "100"}], keys),
         do: endpoints |> Enum.find(&(&1["url"] == url)) |> found()
  end

  defp found(nil), do: {:ok, nil}
  defp found(endpoint), do: built(endpoint)

  # A new destination answers its signing secret once, only when asked for it.
  defp create(url, %{api: :v2} = setup, keys) do
    params = %{
      "name" => "Mishka Pay",
      "type" => "webhook_endpoint",
      "webhook_endpoint" => %{"url" => url},
      "event_payload" => Atom.to_string(setup.events),
      "enabled_events" => names(setup.events),
      "events_from" => events_from(setup.accounts),
      "snapshot_api_version" => snapshot_version(setup.events),
      "include" => ["webhook_endpoint.signing_secret", "webhook_endpoint.url"]
    }

    with {:ok, destination} <- Stripe.request(:post, @destinations, without_nil(params), keys),
         do: built(destination)
  end

  defp create(url, %{api: :v1} = setup, keys) do
    params = %{
      "url" => url,
      "enabled_events" => names(:snapshot),
      "api_version" => Stripe.version(),
      "description" => "Mishka Pay",
      "connect" => setup.accounts || nil
    }

    with {:ok, endpoint} <- Stripe.request(:post, @endpoints, params, keys), do: built(endpoint)
  end

  defp add_missing(endpoint, setup, keys) do
    case missing(endpoint, setup) do
      [] ->
        {:ok, endpoint}

      missing ->
        events = Enum.sort(endpoint.enabled_events ++ missing)

        with {:ok, updated} <-
               Stripe.request(
                 :post,
                 path(endpoint.api, endpoint.id),
                 change(endpoint.api, events),
                 keys
               ),
             do: built(updated)
    end
  end

  defp change(:v2, events),
    do: %{"enabled_events" => events, "include" => ["webhook_endpoint.url"]}

  defp change(:v1, events), do: %{"enabled_events" => events}

  defp switch(tenant, id, to) do
    with {:ok, api} <- api_of(id),
         {:ok, keys} <- Credentials.fetch("stripe", tenant),
         {:ok, answer} <- switched(api, id, to, keys),
         do: built(answer)
  end

  defp switched(:v2, id, to, keys),
    do: Stripe.request(:post, "#{path(:v2, id)}/#{to}", %{}, keys)

  defp switched(:v1, id, to, keys),
    do: Stripe.request(:post, path(:v1, id), %{"disabled" => to == :disable}, keys)

  defp missing(nil, setup), do: names(setup.events)

  defp missing(%__MODULE__{enabled_events: events}, setup) do
    case "*" in events do
      true -> []
      false -> names(setup.events) -- events
    end
  end

  defp names(:thin), do: Stripe.thin_events() |> Map.keys() |> Enum.sort()
  defp names(:snapshot), do: Stripe.handled_events() |> Map.keys() |> Enum.sort()

  defp events_from(true), do: ["@self", "@accounts"]
  defp events_from(false), do: ["@self"]

  defp snapshot_version(:snapshot), do: Stripe.version()
  defp snapshot_version(:thin), do: nil

  defp without_nil(params), do: Map.reject(params, fn {_name, value} -> is_nil(value) end)

  defp path(:v2, id), do: "#{@destinations}/#{id}"
  defp path(:v1, id), do: "#{@endpoints}/#{id}"

  # An event destination's id starts with `ed_`; a v1 endpoint's, listed among them too, `we_`.
  defp api_of("ed_" <> _ = id), do: id |> Stripe.stripe_id("ed_", :endpoint_id) |> api_if(:v2)
  defp api_of("we_" <> _ = id), do: id |> Stripe.stripe_id("we_", :endpoint_id) |> api_if(:v1)

  defp api_of(_id),
    do:
      MishkaPay.ProviderKit.invalid(
        :endpoint_id,
        MishkaPay.Messages.text(:stripe_id, field: :endpoint_id, prefix: "ed_ or we_")
      )

  defp api_if(:ok, api), do: {:ok, api}
  defp api_if(error, _api), do: error

  defp built(%{"object" => "v2.core.event_destination"} = destination) do
    webhook = destination["webhook_endpoint"] || %{}

    %{
      id: destination["id"],
      url: webhook["url"],
      enabled_events: destination["enabled_events"] || [],
      status: status(destination["status"]),
      events: payload(destination["event_payload"]),
      api: api_name(destination["id"]),
      events_from: destination["events_from"] || [],
      api_version: destination["snapshot_api_version"],
      secret: webhook["signing_secret"]
    }
    |> builder()
    |> Errors.from_builder()
  end

  defp built(endpoint) do
    %{
      id: endpoint["id"],
      url: endpoint["url"],
      enabled_events: endpoint["enabled_events"] || [],
      status: status(endpoint["status"]),
      events: :snapshot,
      api: :v1,
      events_from: ["@self"],
      api_version: endpoint["api_version"],
      secret: endpoint["secret"]
    }
    |> builder()
    |> Errors.from_builder()
  end

  defp api_name("we_" <> _id), do: :v1
  defp api_name(_destination), do: :v2

  defp payload("thin"), do: :thin
  defp payload("snapshot"), do: :snapshot
  defp payload(_other), do: nil

  defp status("enabled"), do: :enabled
  defp status("disabled"), do: :disabled
  defp status(_other), do: nil
end

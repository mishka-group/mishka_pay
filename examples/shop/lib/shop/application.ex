defmodule Shop.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Shop.Pay.TelemetryFeed.attach()

    # Mishka Pay's plugins: Stripe as the provider, the shop's keys and settings, then the
    # listeners `MishkaPay.Ash.Resource` made for `Shop.Pay`: the inbox that stores each webhook
    # (first, before the failing listener) and the syncs that keep the payments, subscriptions,
    # customers and disputes tables. Last, the live feed.
    children =
      [
        ShopWeb.Telemetry,
        Shop.Repo,
        {DNSCluster, query: Application.get_env(:shop, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Shop.PubSub},
        {Oban, AshOban.config(Application.fetch_env!(:shop, :ash_domains), oban())},
        # mishka_installer's plugin registry when nothing else starts it, before every plugin.
        # The providers (Stripe, PayPal) are started by Mishka Pay's own application.
        MishkaPay.Registry,
        Shop.Pay.Keys,
        Shop.Pay.Gate
      ] ++
        MishkaPay.Ash.listeners(Shop.Pay) ++
        [
          Shop.Pay.FailingListener,
          # Every payment, subscription, customer and dispute change on Shop.PubSub, per site.
          Shop.Pay.Broadcast,
          ShopWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Shop.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp oban, do: Application.fetch_env!(:shop, Oban)

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ShopWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

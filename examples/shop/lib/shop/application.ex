defmodule Shop.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ShopWeb.Telemetry,
      Shop.Repo,
      {DNSCluster, query: Application.get_env(:shop, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Shop.PubSub},
      {Oban, AshOban.config(Application.fetch_env!(:shop, :ash_domains), oban())},
      # Mishka Pay's plugins: Stripe as the provider, the shop's keys and settings, the inbox
      # that stores each webhook, the sync that keeps the payments table, and the live feed.
      MishkaPay.Providers.Stripe,
      Shop.Pay.Keys,
      Shop.Pay.Inbox,
      Shop.Pay.PaymentSync,
      Shop.Pay.LiveFeed,
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

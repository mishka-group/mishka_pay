# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Local secrets from `.env` (in .gitignore), so `mix phx.server` is all it takes. A variable set in
# the shell wins over the file.
env_file = Path.expand("../.env", __DIR__)

if config_env() != :prod and File.exists?(env_file) do
  for line <- File.stream!(env_file),
      line = String.trim(line),
      line != "" and not String.starts_with?(line, "#"),
      [name, value] = String.split(line, "=", parts: 2),
      value != "",
      is_nil(System.get_env(name)),
      do: System.put_env(name, value)
end

config :shop,
  ecto_repos: [Shop.Repo],
  ash_domains: [Shop.Pay, Shop.Accounts],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# The inbox works each Stripe webhook as an AshOban job on this queue.
config :shop, Oban,
  engine: Oban.Engines.Basic,
  repo: Shop.Repo,
  queues: [mishka_pay_inbox: 5],
  plugins: [{Oban.Plugins.Cron, []}]

# Ash as the Mishka libraries configure it.
config :ash,
  default_string_length_count: :codepoints,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true

config :spark, formatter: [remove_parens?: true, "Ash.Resource": [], "Ash.Domain": []]

# The shop converts no currencies.
config :ex_money, auto_start_exchange_rate_service: false

# Providers, keys and listeners are mishka_installer plugins; the installer keeps its registry here.
config :mishka_installer, MishkaInstaller.MnesiaRepo,
  mnesia_dir: Path.expand("../.mnesia/#{config_env()}", __DIR__),
  essential: [MishkaInstaller.Event.Event, MishkaInstaller.Installer.Installer]

# Configure the endpoint
config :shop, ShopWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ShopWeb.ErrorHTML, json: ShopWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Shop.PubSub,
  live_view: [signing_salt: "6YcZt3qi"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  shop: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  shop: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

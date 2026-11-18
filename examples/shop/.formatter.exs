[
  import_deps: [:ecto, :ecto_sql, :phoenix, :ash, :ash_postgres, :ash_oban, :mishka_pay],
  subdirectories: ["priv/*/migrations"],
  plugins: [Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  # Deprecated syntax (`unless`, ...) fails `mix format --check-formatted`, as in the library.
  migrate: true,
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]

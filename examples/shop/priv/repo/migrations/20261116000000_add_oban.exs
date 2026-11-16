defmodule Shop.Repo.Migrations.AddOban do
  use Ecto.Migration

  # Oban's own tables: the inbox works each webhook as an Oban job.
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down(version: 1)
end

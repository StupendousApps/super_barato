defmodule SuperBarato.Repo.Migrations.CreateCrawlerSchedules do
  use Ecto.Migration

  def change do
    create table(:crawler_schedules) do
      # Chain id, e.g. "unimarc". String (not enum) so adding a new
      # chain doesn't require a migration — validated in the schema.
      add :chain, :string, null: false

      # What gets fired: "discover_categories" or "discover_products".
      # Kept as string for the same future-proofing reason.
      add :kind, :string, null: false

      # Weekly cadence stored as comma-separated primitives.
      #   days:  "mon"        | "mon,tue,wed,thu,fri,sat,sun"
      #   times: "04:00:00"   | "05:00:00,14:30:00"
      add :days, :string, null: false
      add :times, :string, null: false

      add :active, :boolean, null: false, default: true

      # Free-form admin note (e.g. "paused after rate-limit incident").
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    # One row per (chain, kind). Add a `name` column + drop this if you
    # ever want more than one schedule of the same kind on a chain.
    create unique_index(:crawler_schedules, [:chain, :kind])
  end
end

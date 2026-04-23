defmodule SuperBarato.Repo.Migrations.CreateProducts do
  use Ecto.Migration

  def change do
    create table(:products) do
      add :ean, :string
      add :canonical_name, :string
      add :brand, :string
      add :image_url, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:products, [:ean], where: "ean IS NOT NULL")
  end
end

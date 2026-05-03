defmodule SuperBarato.Repo.Migrations.ProductsThumbnailEmbed do
  use Ecto.Migration

  @doc """
  Migrate `products.thumbnail_key` (single R2 object key) to
  `products.thumbnail` — a JSON-encoded `StupendousThumbnails.Image`
  embed with one variant per product. Existing R2 objects keep their
  current keys; the embed just points at them.
  """
  def up do
    alter table(:products) do
      add :thumbnail, :map
    end

    flush()

    public_base = public_base() || "https://thumbnails.example/super-barato"

    # Backfill in pure SQL so the migration doesn't depend on app
    # code. Build a one-variant Image JSON literal for every product
    # whose thumbnail_key is set.
    execute("""
    UPDATE products
    SET thumbnail = json_object(
      'variants',
      json_array(
        json_object(
          'size', 400,
          'format', 'webp',
          'url', '#{public_base}/' || thumbnail_key,
          'key', thumbnail_key
        )
      )
    )
    WHERE thumbnail_key IS NOT NULL AND thumbnail_key != ''
    """)

    alter table(:products) do
      remove :thumbnail_key
    end
  end

  def down do
    alter table(:products) do
      add :thumbnail_key, :string
    end

    flush()

    # Best-effort: pull the first variant's key out of the JSON
    # embed for each product.
    execute("""
    UPDATE products
    SET thumbnail_key = json_extract(thumbnail, '$.variants[0].key')
    WHERE thumbnail IS NOT NULL
    """)

    alter table(:products) do
      remove :thumbnail
    end
  end

  defp public_base do
    cfg = Application.get_all_env(:stupendous_thumbnails)

    case cfg[:public_base] do
      nil ->
        if cfg[:account_id] && cfg[:bucket],
          do: "https://#{cfg[:account_id]}.r2.cloudflarestorage.com/#{cfg[:bucket]}",
          else: nil

      base ->
        String.trim_trailing(base, "/")
    end
  end
end

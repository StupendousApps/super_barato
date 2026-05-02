defmodule SuperBarato.Repo.Migrations.BackfillChainListingCategories do
  use Ecto.Migration
  import Ecto.Query

  alias SuperBarato.Catalog
  alias SuperBarato.Catalog.{ChainListing, ChainListingCategory}
  alias SuperBarato.Repo

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    flush()

    orphans =
      Repo.all(
        from l in ChainListing,
          left_join: clc in ChainListingCategory,
          on: clc.chain_listing_id == l.id,
          where: is_nil(clc.id) and fragment("json_array_length(?) > 0", l.category_paths),
          select: {l.id, l.chain, l.category_paths}
      )

    IO.puts("Backfilling #{length(orphans)} orphan listings...")

    Enum.each(orphans, fn {listing_id, chain, paths} ->
      paths
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.each(fn slug ->
        cat_id = Catalog.ensure_chain_category!(chain, slug)

        Repo.insert_all(
          ChainListingCategory,
          [%{chain_listing_id: listing_id, chain_category_id: cat_id}],
          on_conflict: :nothing
        )
      end)
    end)
  end

  def down, do: :ok
end

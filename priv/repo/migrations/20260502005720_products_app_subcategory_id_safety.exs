defmodule SuperBarato.Repo.Migrations.ProductsAppSubcategoryIdSafety do
  use Ecto.Migration

  # Safety net for production DBs that pre-date the migration squash.
  #
  # The squashed `20260429000000_init.exs` adds `products.app_subcategory_id`
  # as part of an `alter table` near the bottom of the file, but the
  # production DB was already migrated under the OLD multi-file
  # sequence whose `init` only created the column-free `products`
  # table. The column-adding ALTER lived in a later migration that
  # got dropped during the squash, leaving the prod schema short of
  # the expected column.
  #
  # This migration re-adds the column (and its index) idempotently
  # so it's a no-op on fresh dev DBs that already have it from the
  # squashed init.
  def change do
    unless column_exists?(:products, :app_subcategory_id) do
      alter table(:products) do
        add :app_subcategory_id, references(:app_subcategories, on_delete: :nilify_all)
      end

      create_if_not_exists index(:products, [:app_subcategory_id])
    end
  end

  defp column_exists?(table, column) do
    {:ok, %{rows: rows}} = repo().query("PRAGMA table_info(#{table})", [])
    Enum.any?(rows, fn [_cid, name | _] -> name == to_string(column) end)
  end
end

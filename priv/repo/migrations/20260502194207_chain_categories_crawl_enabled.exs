defmodule SuperBarato.Repo.Migrations.ChainCategoriesCrawlEnabled do
  use Ecto.Migration

  # Per-chain_category opt-out flag for the crawler. Existing rows
  # default to TRUE so production state carries over unchanged. The
  # heuristic that auto-disables non-grocery branches (toys, home,
  # tech) is applied only to *new* rows discovered by the crawler;
  # see `Catalog.default_crawl_enabled?/2`.
  def change do
    alter table(:chain_categories) do
      add :crawl_enabled, :boolean, null: false, default: true
    end
  end
end

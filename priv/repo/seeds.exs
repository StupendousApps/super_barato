# Top-level seed orchestrator. Runs each seed script in dependency
# order — chain_categories before app_chain_mappings, etc. Each
# script is idempotent, so re-running this file is safe.
#
#   mix run priv/repo/seeds.exs
#
# To re-run a single piece, invoke its file directly:
#
#   mix run priv/repo/seed_chain_categories.exs

scripts = [
  "seed_admin.exs",
  "seed_chain_categories.exs",
  "seed_app_categories.exs",
  "seed_app_chain_mappings.exs"
]

Enum.each(scripts, fn name ->
  IO.puts("\n== #{name} ==")
  Code.eval_file(Path.expand(name, __DIR__))
end)

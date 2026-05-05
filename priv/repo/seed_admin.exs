# Bootstrap a superadmin user + the crawler schedule rows. Run as
# part of the orchestrator (preferred) or directly:
#
#   mix run priv/repo/seed_admin.exs
#
# Idempotent — re-running refreshes the password / superadmin flag
# and seeds any schedule rows missing from the table.

# ── Superadmin ──────────────────────────────────────────────────────
# Delegate to stupendous_admin's library-owned seed. Provides
# ADMIN_EMAIL / ADMIN_PASSWORD defaults for local dev/test; prod
# must set them explicitly via env (see config/deploy.yml secrets).
System.put_env("ADMIN_EMAIL", System.get_env("ADMIN_EMAIL") || "francisco.ceruti@gmail.com")
System.put_env("ADMIN_PASSWORD", System.get_env("ADMIN_PASSWORD") || "correct-horse-battery")

Code.eval_file(Application.app_dir(:stupendous_admin, "priv/repo/seeds.exs"))

# ── Crawler schedules ───────────────────────────────────────────────
# One row per (chain, kind) described in config/config.exs. Only
# inserts missing rows, so edits from the admin UI aren't clobbered
# on re-seed.
n = SuperBarato.Crawler.Schedules.seed_from_config()
IO.puts("Seeded crawler schedules (#{n} config entries processed)")

# Bootstrap a superadmin user + the crawler schedule rows. Run as
# part of the orchestrator (preferred) or directly:
#
#   mix run priv/repo/seed_admin.exs
#
# Idempotent — re-running upserts the user (refreshes role/password)
# and seeds any schedule rows missing from the table.

alias SuperBarato.Accounts.User
alias SuperBarato.Repo

email = "francisco.ceruti@gmail.com"
password = "1234"

# Bypass User.password_changeset (which enforces min 12 chars) —
# seed-only shortcut for dev. Never use a 4-char password in prod.
user =
  case Repo.get_by(User, email: email) do
    nil ->
      %User{
        email: email,
        hashed_password: Bcrypt.hash_pwd_salt(password),
        role: :superadmin,
        confirmed_at: DateTime.utc_now(:second)
      }
      |> Repo.insert!()

    existing ->
      existing
      |> Ecto.Changeset.change(%{
        hashed_password: Bcrypt.hash_pwd_salt(password),
        role: :superadmin,
        confirmed_at: existing.confirmed_at || DateTime.utc_now(:second)
      })
      |> Repo.update!()
  end

IO.puts("Seeded superadmin: #{user.email} (role=#{user.role})")

# Crawler schedules — one row per (chain, kind) described in
# config/config.exs. Only inserts missing rows, so edits from the
# admin UI aren't clobbered on re-seed.
n = SuperBarato.Crawler.Schedules.seed_from_config()
IO.puts("Seeded crawler schedules (#{n} config entries processed)")

# Script for populating the database. Run with:
#
#     mix run priv/repo/seeds.exs
#
# Idempotent — safe to re-run.

alias SuperBarato.Repo
alias SuperBarato.Accounts.User

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

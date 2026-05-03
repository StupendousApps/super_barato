# Bootstrap a superadmin user + the crawler schedule rows. Run as
# part of the orchestrator (preferred) or directly:
#
#   mix run priv/repo/seed_admin.exs
#
# Idempotent — re-running refreshes the password (no role concept on
# AdminUser today) and seeds any schedule rows missing from the table.

alias StupendousAdmin.Accounts
alias StupendousAdmin.Accounts.AdminUser
alias SuperBarato.Repo

email = System.get_env("ADMIN_EMAIL") || "francisco.ceruti@gmail.com"
password = System.get_env("ADMIN_PASSWORD") || "correct-horse-battery"

admin =
  case Accounts.get_admin_user_by_email(email) do
    nil ->
      {:ok, admin} = Accounts.register_admin_user(%{email: email, password: password})
      admin

    %AdminUser{} = existing ->
      {:ok, refreshed} =
        Accounts.reset_admin_user_password(existing, %{
          password: password,
          password_confirmation: password
        })

      refreshed
  end

IO.puts("Seeded admin: #{admin.email}")

# Crawler schedules — one row per (chain, kind) described in
# config/config.exs. Only inserts missing rows, so edits from the
# admin UI aren't clobbered on re-seed.
n = SuperBarato.Crawler.Schedules.seed_from_config()
IO.puts("Seeded crawler schedules (#{n} config entries processed)")

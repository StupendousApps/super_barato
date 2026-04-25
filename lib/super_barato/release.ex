defmodule SuperBarato.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :super_barato

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Seed the production DB. Mirrors `priv/repo/seeds.exs` but is callable
  from a release (where `priv/repo/seeds.exs` isn't shipped). Idempotent
  — re-running is safe.
  """
  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, fn _ -> seed_data() end)
    end
  end

  defp seed_data do
    alias SuperBarato.Accounts.User
    alias SuperBarato.Crawler.Schedules
    alias SuperBarato.Repo

    email = "francisco.ceruti@gmail.com"
    password = "1234"

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

    n = Schedules.seed_from_config()
    IO.puts("Seeded crawler schedules (#{n} config entries processed)")
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end

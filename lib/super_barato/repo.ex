defmodule SuperBarato.Repo do
  use Ecto.Repo,
    otp_app: :super_barato,
    adapter: Ecto.Adapters.Postgres
end

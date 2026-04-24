defmodule SuperBarato.Crawler.Schedules do
  @moduledoc """
  DB-backed crawler schedules — read at boot by `SuperBarato.Application`
  to build each chain's Cron input, and edited via the admin UI.

  `seed_from_config/0` is idempotent and runs at app boot (or from
  `priv/repo/seeds.exs`) to populate the table from the defaults in
  `config/config.exs` on first deploy. Subsequent edits stick.
  """

  import Ecto.Query

  alias SuperBarato.{Crawler, Repo}
  alias SuperBarato.Crawler.Schedule

  @doc "All schedules, ordered by chain then kind for stable admin display."
  def list do
    Schedule
    |> order_by([s], asc: s.chain, asc: s.kind)
    |> Repo.all()
  end

  @doc "Schedules for a single chain (active + inactive)."
  def list_for(chain) when is_atom(chain), do: list_for(Atom.to_string(chain))

  def list_for(chain) when is_binary(chain) do
    Schedule
    |> where([s], s.chain == ^chain)
    |> order_by([s], asc: s.kind)
    |> Repo.all()
  end

  def get!(id), do: Repo.get!(Schedule, id)

  def change_schedule(%Schedule{} = s, attrs \\ %{}),
    do: Schedule.changeset(s, attrs)

  def update(%Schedule{} = s, attrs) do
    s |> Schedule.changeset(attrs) |> Repo.update()
  end

  @doc """
  `{cadence, mfa}` entries for a chain — the list Chain.Cron consumes.
  Filters out `active: false` rows.
  """
  def cron_entries(chain) when is_atom(chain) do
    for schedule <- list_for(chain),
        {:ok, entry} <- [Schedule.to_cron_entry(schedule)],
        do: entry
  end

  @doc """
  Ensure there's a row in the table for every `(chain, kind)` pair
  described in `config/config.exs`. Existing rows are left alone —
  this only inserts missing defaults.
  """
  def seed_from_config do
    entries =
      :super_barato
      |> Application.get_env(SuperBarato.Crawler, [])
      |> Keyword.get(:chains, [])
      |> Enum.flat_map(fn {chain, chain_opts} ->
        for {{:weekly, days, times}, mfa} <- Keyword.get(chain_opts, :schedule, []) do
          %{
            chain: Atom.to_string(chain),
            kind: infer_kind(mfa),
            days: Schedule.days_to_string(days),
            times: Schedule.times_to_string(times),
            active: true
          }
        end
      end)

    Enum.each(entries, fn attrs ->
      exists? =
        Repo.exists?(
          from s in Schedule, where: s.chain == ^attrs.chain and s.kind == ^attrs.kind
        )

      if not exists? do
        %Schedule{}
        |> Schedule.changeset(attrs)
        |> Repo.insert!()
      end
    end)

    length(entries)
  end

  # MFA → kind. Match the two shapes the project uses today; fall back
  # to raise so unexpected MFAs aren't silently discarded.
  defp infer_kind({SuperBarato.Crawler.Chain.Queue, :push, [_chain, {:discover_categories, _}]}),
    do: "discover_categories"

  defp infer_kind({SuperBarato.Crawler.Chain.ProductProducer, :run, [_]}),
    do: "discover_products"

  defp infer_kind(other),
    do: raise("Schedules.seed_from_config/0 can't map MFA: #{inspect(other)}")

  @doc false
  # Used by the admin UI to display known chains as tabs.
  def known_chains, do: Crawler.known_chains()
end

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

  @doc """
  Schedules ordered by chain then kind. Optional filters:

    * `:chain` — atom or string chain id, or nil/"" for all.
    * `:kind`  — "discover_categories" | "discover_products", or nil/"" for all.
  """
  def list(opts \\ []) do
    Schedule
    |> filter_chain(opts[:chain])
    |> filter_kind(opts[:kind])
    |> order_by([s], asc: s.chain, asc: s.kind)
    |> Repo.all()
  end

  defp filter_chain(q, nil), do: q
  defp filter_chain(q, ""), do: q
  defp filter_chain(q, chain) when is_atom(chain), do: where(q, [s], s.chain == ^Atom.to_string(chain))
  defp filter_chain(q, chain) when is_binary(chain), do: where(q, [s], s.chain == ^chain)

  defp filter_kind(q, nil), do: q
  defp filter_kind(q, ""), do: q
  defp filter_kind(q, kind) when is_binary(kind), do: where(q, [s], s.kind == ^kind)

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

  def create(attrs) do
    %Schedule{}
    |> Schedule.changeset(attrs)
    |> Repo.insert()
    |> reload_after_mutation()
  end

  def update(%Schedule{} = s, attrs) do
    s
    |> Schedule.changeset(attrs)
    |> Repo.update()
    |> reload_after_mutation()
  end

  def delete(%Schedule{} = s) do
    with {:ok, deleted} <- Repo.delete(s) do
      reload_chain(deleted.chain)
      {:ok, deleted}
    end
  end

  # After insert/update: ask the running Cron (if any) to re-arm its
  # timers. Wrapped in a helper so all three mutations converge on a
  # single reload call site.
  defp reload_after_mutation({:ok, %Schedule{chain: chain}} = ok) do
    reload_chain(chain)
    ok
  end

  defp reload_after_mutation(other), do: other

  defp reload_chain(chain_str) when is_binary(chain_str) do
    chain_str
    |> String.to_existing_atom()
    |> SuperBarato.Crawler.Chain.Cron.reload()
  rescue
    ArgumentError -> :ok
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

  defp infer_kind({SuperBarato.Crawler.Cencosud.ProductProducer, :run, [_]}),
    do: "discover_products"

  defp infer_kind(other),
    do: raise("Schedules.seed_from_config/0 can't map MFA: #{inspect(other)}")

  @doc false
  # Used by the admin UI to display known chains as tabs.
  def known_chains, do: Crawler.known_chains()
end

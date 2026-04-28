defmodule SuperBarato.Linker.Backfill do
  @moduledoc """
  One-shot batch linker. Streams every active `chain_listing` and
  routes it through `Linker.find_or_create_product_for_listing/1` +
  `Linker.set_listing_link/3` — the same path the streaming Worker
  uses, just in one big sweep.

  Idempotent — re-running picks up new listings, leaves existing
  links alone, and folds single-chain placeholders into canonical
  EAN-keyed Products as soon as a listing acquires an EAN.
  """

  import Ecto.Query
  require Logger

  alias SuperBarato.Catalog.ChainListing
  alias SuperBarato.Linker
  alias SuperBarato.Repo

  @doc """
  Run over every active chain_listing. Returns
  `%{listings_total:, ean_canonical: N, single_chain: N, skipped: N}`.
  """
  def run(opts \\ []) do
    log? = Keyword.get(opts, :log, true)
    if log?, do: Logger.info("linker backfill: streaming chain_listings…")

    counts = %{ean_canonical: 0, single_chain: 0, skipped: 0}
    total = Repo.aggregate(from(l in ChainListing, where: l.active == true), :count)

    {:ok, result} =
      Repo.transaction(
        fn ->
          from(l in ChainListing, where: l.active == true)
          |> Repo.stream(max_rows: 200)
          |> Enum.reduce(counts, &link_one/2)
        end,
        timeout: :infinity
      )

    final = Map.put(result, :listings_total, total)
    if log?, do: Logger.info("linker backfill: done #{inspect(final)}")
    final
  end

  defp link_one(%ChainListing{} = listing, acc) do
    case Linker.identifiers_for_listing(listing) do
      [] ->
        Map.update!(acc, :skipped, &(&1 + 1))

      _ids ->
        # One transaction per listing — a partial failure rolls back
        # the Product creation along with the link, so the catalog
        # never carries phantom Products with zero listings.
        {:ok, source} =
          Repo.transaction(fn ->
            {_action, product, source} =
              Linker.find_or_create_product_for_listing(listing)

            Linker.set_listing_link(product.id, listing.id,
              source: source,
              confidence: confidence_for(source)
            )

            source
          end)

        Map.update!(acc, source_to_key(source), &(&1 + 1))
    end
  end

  defp source_to_key("ean_canonical"), do: :ean_canonical
  defp source_to_key("single_chain"), do: :single_chain

  defp confidence_for("ean_canonical"), do: 1.0
  defp confidence_for("single_chain"), do: 0.5
  defp confidence_for(_), do: nil
end

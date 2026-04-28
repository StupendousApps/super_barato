defmodule SuperBarato.Linker.Worker do
  @moduledoc """
  Single-process consumer of "a new chain_listing was inserted"
  signals from the crawler. Given a freshly inserted listing, it
  canonicalizes the EAN, finds-or-creates the matching
  `Catalog.Product`, and writes the `product_listings` row via
  `SuperBarato.Linker.link/3`.

  Casts only — fire-and-forget from the crawler's `Chain.Results`.
  Serializing through one process means two near-simultaneous
  listings for the same EAN can't race two `Product` inserts past
  the unique index.

  Listings without a usable EAN (Tottus's loose meat, produce sold by
  weight, anything where the chain doesn't expose a barcode) are linked
  to a single-chain placeholder Product instead of being skipped, so
  every listing produces exactly one Product on first sight. Cross-chain
  matching for those long-tail rows is left to `Linker.merge_products/2`
  (admin or a future fuzzy pass).
  """

  use GenServer
  require Logger

  alias SuperBarato.Catalog.ChainListing
  alias SuperBarato.Linker
  alias SuperBarato.Repo

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueue a freshly inserted `chain_listing` for product matching.
  Non-blocking. Worker resolves it in the order received.
  """
  def link_listing(chain_listing_id) when is_integer(chain_listing_id) do
    GenServer.cast(__MODULE__, {:link, chain_listing_id})
  end

  ## GenServer

  @impl true
  def init(_opts) do
    Logger.metadata(role: :linker)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:link, chain_listing_id}, state) do
    try do
      link_one(chain_listing_id)
    rescue
      err ->
        Logger.warning(
          "linker: failed for chain_listing_id=#{chain_listing_id}: #{inspect(err)}"
        )
    end

    {:noreply, state}
  end

  defp link_one(id) do
    case Repo.get(ChainListing, id) do
      nil ->
        :skip

      %ChainListing{} = listing ->
        cond do
          # `Catalog.upsert_listing/1` already refuses to insert
          # rows without a price, so a no-price listing here means
          # one of: a stale row from before that rule landed, an
          # admin-edited row, or a code path that bypasses the
          # catalog. Defense in depth — skip rather than anchor a
          # Product that wouldn't pass the catalog's invariants.
          is_nil(listing.current_regular_price) or listing.current_regular_price <= 0 ->
            :skip

          Linker.identifiers_for_listing(listing) == [] ->
            # No usable identifier at all (no EAN, no chain_sku) —
            # nothing safe to anchor a Product on. Leave unlinked.
            :skip

          true ->
            # Atomic find-or-create + link. Wrapping both in one
            # transaction means a `set_listing_link` failure (FK
            # violation, exception inside `link/3`) rolls back the
            # Product creation too — otherwise we'd accumulate
            # Products that no listing references.
            Repo.transaction(fn ->
              {_action, product, source} =
                Linker.find_or_create_product_for_listing(listing)

              Linker.set_listing_link(product.id, listing.id,
                source: source,
                confidence: confidence_for(source),
                linked_at: now()
              )
            end)
        end
    end
  end

  defp confidence_for("ean_canonical"), do: 1.0
  defp confidence_for("single_chain"), do: 0.5
  defp confidence_for(_), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end

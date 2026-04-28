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

  Listings whose `ean` doesn't canonicalize (nil, malformed, granel
  with no barcode) are silently skipped — `Linker.Backfill` periodically
  retries with a wider net (and admins can link the long tail manually).
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
    with %ChainListing{} = listing <- Repo.get(ChainListing, id),
         key when is_binary(key) <- Linker.canonical_key_for_listing(listing) do
      seed = %{name: listing.name, brand: listing.brand, image_url: listing.image_url}
      {_action, product} = Linker.find_or_create_product_for_ean(key, seed)

      Linker.link(product.id, listing.id,
        source: Linker.source_ean_canonical(),
        confidence: 1.0,
        linked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
    else
      _ -> :skip
    end
  end
end

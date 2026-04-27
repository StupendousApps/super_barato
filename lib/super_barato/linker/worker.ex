defmodule SuperBarato.Linker.Worker do
  @moduledoc """
  Single-process consumer of "a new chain_listing was inserted"
  signals from the crawler. The owner of all auto-link decisions:
  given a freshly inserted listing, decides whether it matches an
  existing `Catalog.Product` (today by EAN; later layered with
  brand+name fuzzy and any manual overrides), creates a Product if
  no match exists, and writes the `product_listings` row via
  `SuperBarato.Linker.link/3`.

  Casts only — fire-and-forget from the crawler's `Chain.Results`.
  Inflight cast queue serializes link writes so concurrent inserts
  for the same EAN can't race two new Product rows.

  Stub for now: `link_listing/1` casts to the worker, `handle_cast`
  logs and returns. Real matching arrives in a follow-up commit.
  """

  use GenServer
  require Logger

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
    Logger.debug("linker: received chain_listing_id=#{chain_listing_id} (no-op stub)")
    {:noreply, state}
  end
end

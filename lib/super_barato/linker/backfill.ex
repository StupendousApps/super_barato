defmodule SuperBarato.Linker.Backfill do
  @moduledoc """
  One-shot batch linker: groups every `chain_listing` by canonical
  GTIN-13 (`Identity.canonicalize_gtin13/1` over `ean`), finds-or-creates
  the matching `Catalog.Product`, and writes a `product_listings` row
  per listing with `source: "ean_canonical"`.

  Two-pass and idempotent — re-running picks up new listings, leaves
  existing links untouched (the unique index on (product_id,
  chain_listing_id) absorbs the redundant inserts).

  Listings whose `ean` doesn't canonicalize to a valid GTIN-13 are
  skipped here; later passes (name+brand within category, manual) own
  the long tail.
  """

  import Ecto.Query
  require Logger

  alias SuperBarato.Catalog
  alias SuperBarato.Catalog.{ChainListing, Product, ProductEan}
  alias SuperBarato.Linker
  alias SuperBarato.Linker.Identity
  alias SuperBarato.Repo

  @doc """
  Run the EAN-canonical pass over every active chain_listing. Returns
  `%{listings_total:, canonicalized:, products_seen:, products_created:,
  links_written:}`.
  """
  def run(opts \\ []) do
    log? = Keyword.get(opts, :log, true)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if log?, do: Logger.info("linker backfill: streaming chain_listings…")

    # Pull just what we need (id + ean + name + brand + image_url so we
    # can seed Product fields when creating). Keeps the in-memory map
    # small.
    rows =
      from(l in ChainListing,
        where: l.active == true,
        select: {l.id, l.ean, l.name, l.brand, l.image_url}
      )
      |> Repo.all()

    # Two parallel keyspaces — GTIN-13 (canonicalized via the
    # full normalisation flow) and EAN-8 (used verbatim, no
    # transform). A listing's EAN goes into whichever bucket its
    # value canonicalizes to; if neither fires, the listing stays
    # unlinked and is admin work later.
    {by_key, canonicalized} =
      Enum.reduce(rows, {%{}, 0}, fn {id, ean, name, brand, image_url}, {acc, n} ->
        canonical_key =
          Identity.canonicalize_gtin13(ean) || Identity.canonicalize_ean8(ean)

        case canonical_key do
          nil ->
            {acc, n}

          k ->
            entry = %{id: id, name: name, brand: brand, image_url: image_url}
            {Map.update(acc, k, [entry], &[entry | &1]), n + 1}
        end
      end)

    if log? do
      Logger.info(
        "linker backfill: #{length(rows)} listings, #{canonicalized} canonicalized, " <>
          "#{map_size(by_key)} distinct EAN keys"
      )
    end

    # Find-or-create one Product per EAN key (GTIN-13 or EAN-8).
    # Done one at a time so the unique index handles concurrent
    # backfill runs safely; on SQLite WAL the throughput is fine.
    {products_created, products_seen, links_written} =
      Enum.reduce(by_key, {0, 0, 0}, fn {key, listings}, {created, seen, links} ->
        # Use the first listing's display fields as Product seeds. The
        # cross-chain canonicalization step happens in a separate pass
        # later — for now any listing's name/brand is "good enough" for
        # a placeholder Product the admin can curate.
        seed = List.first(listings)

        {action, product} = upsert_product_by_ean(key, seed)

        new_links =
          Enum.reduce(listings, 0, fn entry, n ->
            case Linker.link(product.id, entry.id,
                   source: Linker.source_ean_canonical(),
                   confidence: 1.0,
                   linked_at: now
                 ) do
              {:ok, _} -> n + 1
              {:error, _} -> n
            end
          end)

        {
          created + if(action == :created, do: 1, else: 0),
          seen + 1,
          links + new_links
        }
      end)

    result = %{
      listings_total: length(rows),
      canonicalized: canonicalized,
      products_seen: products_seen,
      products_created: products_created,
      links_written: links_written
    }

    if log?, do: Logger.info("linker backfill: done #{inspect(result)}")
    result
  end

  # Find-or-create a Product anchored on `ean` via `product_eans`.
  # Returns `{:created | :existed, %Product{}}`. New products always
  # land with exactly one ProductEan; admin merges later if multiple
  # EANs turn out to be the same physical product.
  defp upsert_product_by_ean(ean, seed) do
    case Catalog.get_product_by_ean(ean) do
      %Product{} = p ->
        {:existed, p}

      nil ->
        attrs = %{
          canonical_name: seed.name || "(unnamed)",
          brand: seed.brand,
          image_url: seed.image_url
        }

        Repo.transaction(fn ->
          {:ok, product} =
            %Product{} |> Product.changeset(attrs) |> Repo.insert()

          {:ok, _ean_row} =
            %ProductEan{}
            |> ProductEan.changeset(%{product_id: product.id, ean: ean})
            |> Repo.insert()

          product
        end)
        |> case do
          {:ok, p} -> {:created, p}
        end
    end
  end
end

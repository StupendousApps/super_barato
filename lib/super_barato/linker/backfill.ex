defmodule SuperBarato.Linker.Backfill do
  @moduledoc """
  One-shot batch linker. Streams every active `chain_listing` and
  writes a `product_listings` row for it, creating a `Catalog.Product`
  if needed. Two paths, depending on whether the listing has a
  canonicalizable EAN:

    * **EAN-canonical** — listings whose `ean` canonicalizes to a
      GTIN-13 / EAN-8 cluster. All listings sharing that key get one
      Product (cross-chain). `source: "ean_canonical"`.
    * **Single-chain** — listings with no usable EAN (chains that
      don't expose barcodes for some classes — Tottus's loose meat,
      produce sold by weight). Each listing gets its own placeholder
      Product, no `ProductEan` rows. `source: "single_chain"`.
      Cross-chain merging is left to admin or a future fuzzy pass.

  Idempotent — re-running picks up new listings and leaves existing
  links untouched (the `(product_id, chain_listing_id)` unique index
  absorbs redundant inserts).
  """

  import Ecto.Query
  require Logger

  alias SuperBarato.Catalog.ChainListing
  alias SuperBarato.Linker
  alias SuperBarato.Linker.Identity
  alias SuperBarato.Repo

  @doc """
  Run both passes over every active chain_listing. Returns
  `%{listings_total:, ean_canonical: %{…}, single_chain: %{…}}`.
  """
  def run(opts \\ []) do
    log? = Keyword.get(opts, :log, true)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if log?, do: Logger.info("linker backfill: streaming chain_listings…")

    rows =
      from(l in ChainListing,
        where: l.active == true,
        select: {l.id, l.ean, l.name, l.brand, l.image_url}
      )
      |> Repo.all()

    # Bucket each row into EAN-bucketed (cross-chain candidates) or
    # eanless (single-chain placeholders).
    {by_key, eanless, canonicalized} =
      Enum.reduce(rows, {%{}, [], 0}, fn {id, ean, name, brand, image_url}, {acc, lone, n} ->
        canonical_key =
          Identity.canonicalize_gtin13(ean) || Identity.canonicalize_ean8(ean)

        entry = %{id: id, name: name, brand: brand, image_url: image_url}

        case canonical_key do
          nil -> {acc, [entry | lone], n}
          k -> {Map.update(acc, k, [entry], &[entry | &1]), lone, n + 1}
        end
      end)

    if log? do
      Logger.info(
        "linker backfill: #{length(rows)} listings — " <>
          "#{canonicalized} EAN-canonicalized in #{map_size(by_key)} groups, " <>
          "#{length(eanless)} EAN-less"
      )
    end

    ean_stats = run_ean_canonical(by_key, now)
    single_stats = run_single_chain(eanless, now)

    result = %{
      listings_total: length(rows),
      ean_canonical: ean_stats,
      single_chain: single_stats
    }

    if log?, do: Logger.info("linker backfill: done #{inspect(result)}")
    result
  end

  # EAN-canonical pass: one Product per (canonicalized) EAN key,
  # links every listing that hashed into that bucket.
  defp run_ean_canonical(by_key, now) do
    {created, seen, links} =
      Enum.reduce(by_key, {0, 0, 0}, fn {key, listings}, {created, seen, links} ->
        seed = List.first(listings)
        {action, product} = Linker.find_or_create_product_for_ean(key, seed)

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

    %{products_created: created, products_seen: seen, links_written: links}
  end

  # Single-chain pass: one Product per listing, link it. Idempotent
  # via existing-product-for-listing lookup, so re-running the
  # backfill doesn't duplicate Products.
  defp run_single_chain(eanless, now) do
    Enum.reduce(eanless, %{products_created: 0, links_written: 0}, fn entry, acc ->
      listing = Repo.get(ChainListing, entry.id)

      if is_nil(listing) do
        acc
      else
        {action, product} = Linker.find_or_create_eanless_product_for_listing(listing)

        new_link =
          case Linker.link(product.id, entry.id,
                 source: Linker.source_single_chain(),
                 confidence: 0.5,
                 linked_at: now
               ) do
            {:ok, _} -> 1
            {:error, _} -> 0
          end

        %{
          acc
          | products_created: acc.products_created + if(action == :created, do: 1, else: 0),
            links_written: acc.links_written + new_link
        }
      end
    end)
  end
end

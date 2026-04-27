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

  alias SuperBarato.Catalog.{ChainListing, Product}
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

    {by_gtin, canonicalized} =
      Enum.reduce(rows, {%{}, 0}, fn {id, ean, name, brand, image_url}, {acc, n} ->
        case Identity.canonicalize_gtin13(ean) do
          nil ->
            {acc, n}

          g ->
            entry = %{id: id, name: name, brand: brand, image_url: image_url}
            {Map.update(acc, g, [entry], &[entry | &1]), n + 1}
        end
      end)

    if log? do
      Logger.info(
        "linker backfill: #{length(rows)} listings, #{canonicalized} canonicalized, " <>
          "#{map_size(by_gtin)} distinct GTIN-13"
      )
    end

    # Find-or-create one Product per GTIN-13. Done one at a time so the
    # ean unique index handles concurrent backfill runs safely (we lose
    # bulk-insert speed but gain simplicity; 37k inserts run in seconds
    # on SQLite WAL).
    {products_created, products_seen, links_written} =
      Enum.reduce(by_gtin, {0, 0, 0}, fn {gtin13, listings}, {created, seen, links} ->
        # Use the first listing's display fields as Product seeds. The
        # cross-chain canonicalization step happens in a separate pass
        # later — for now any listing's name/brand is "good enough" for
        # a placeholder Product the admin can curate.
        seed = List.first(listings)

        {action, product} = upsert_product_by_ean(gtin13, seed)

        new_links =
          Enum.reduce(listings, 0, fn entry, n ->
            case Linker.link(product.id, entry.id,
                   source: "ean_canonical",
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

  # Insert-or-fetch a Product keyed on the canonical EAN. Returns
  # `{:created | :existed, %Product{}}`.
  defp upsert_product_by_ean(ean, seed) do
    attrs = %{
      ean: ean,
      canonical_name: seed.name || "(unnamed)",
      brand: seed.brand,
      image_url: seed.image_url
    }

    case %Product{}
         |> Product.changeset(attrs)
         |> Repo.insert(
           on_conflict: :nothing,
           # The unique index on products.ean is partial
           # (`WHERE ean IS NOT NULL`); SQLite requires the same WHERE
           # in the ON CONFLICT target for it to match.
           conflict_target: {:unsafe_fragment, ~s|("ean") WHERE "ean" IS NOT NULL|},
           returning: true
         ) do
      # Returned row has an id → freshly inserted.
      {:ok, %Product{id: id} = p} when is_integer(id) ->
        {:created, p}

      # `on_conflict: :nothing` returns an empty struct on conflict.
      # Fetch the existing row by ean.
      {:ok, _} ->
        {:existed, Repo.get_by!(Product, ean: ean)}
    end
  end
end

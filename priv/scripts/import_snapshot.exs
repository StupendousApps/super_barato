# One-shot import of chain_listings from a prod snapshot DB into the
# current dev database. Run with:
#
#   mix run priv/scripts/import_snapshot.exs [path/to/snapshot.db]
#
# The snapshot has the old pre-`raw`/pre-`identifiers_key` schema —
# we synthesize `identifiers_key` from `chain_sku` + `ean` (the only
# id-shaped fields the snapshot preserves) and leave `raw = %{}`. Good
# enough to exercise the Linker's EAN-canonical matching path; not
# enough for raw-driven fuzzy matching.

alias SuperBarato.Catalog
alias SuperBarato.Crawler.Listing
alias SuperBarato.Linker.Identity

snapshot_path = List.first(System.argv()) || "tmp/prod_snapshot.db"

unless File.exists?(snapshot_path) do
  IO.puts(:stderr, "snapshot not found: #{snapshot_path}")
  System.halt(1)
end

{:ok, conn} = Exqlite.Sqlite3.open(snapshot_path, mode: :readonly)

{:ok, count_stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT COUNT(*) FROM chain_listings")
{:row, [total]} = Exqlite.Sqlite3.step(conn, count_stmt)
:ok = Exqlite.Sqlite3.release(conn, count_stmt)

IO.puts("Importing #{total} chain_listings from #{snapshot_path}")

select_sql = """
SELECT chain, chain_sku, chain_product_id, ean, name, brand, image_url,
       category_path, pdp_url, current_regular_price, current_promo_price,
       current_promotions, active
FROM chain_listings
"""

{:ok, stmt} = Exqlite.Sqlite3.prepare(conn, select_sql)

blank? = fn
  nil -> true
  "" -> true
  _ -> false
end

build_identifiers = fn chain_sku, ean ->
  %{}
  |> then(fn m -> if blank?.(chain_sku), do: m, else: Map.put(m, "sku", chain_sku) end)
  |> then(fn m -> if blank?.(ean), do: m, else: Map.put(m, "ean", ean) end)
end

import_row = fn [
                  chain,
                  chain_sku,
                  chain_product_id,
                  ean,
                  name,
                  brand,
                  image_url,
                  category_path,
                  pdp_url,
                  regular,
                  promo,
                  promotions_json,
                  _active
                ] ->
  identifiers = build_identifiers.(chain_sku, ean)
  identifiers_key = Identity.encode(identifiers)

  promotions =
    case promotions_json do
      nil -> %{}
      "" -> %{}
      s when is_binary(s) ->
        case Jason.decode(s) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end
      _ -> %{}
    end

  listing = %Listing{
    chain: String.to_atom(chain),
    chain_sku: chain_sku,
    chain_product_id: chain_product_id,
    ean: ean,
    name: name || "(unnamed)",
    brand: brand,
    image_url: image_url,
    pdp_url: pdp_url,
    category_path: category_path,
    regular_price: regular,
    promo_price: promo,
    promotions: promotions,
    identifiers_key: identifiers_key,
    raw: %{}
  }

  case Catalog.upsert_listing(listing) do
    {:ok, _action, _row} -> :ok
    {:error, cs} -> {:error, cs}
  end
end

{ok, err, skipped, idx} =
  Stream.repeatedly(fn -> Exqlite.Sqlite3.step(conn, stmt) end)
  |> Stream.take_while(fn
    :done -> false
    {:row, _} -> true
  end)
  |> Enum.reduce({0, 0, 0, 0}, fn {:row, row}, {ok, err, skipped, idx} ->
    next_idx = idx + 1

    if rem(next_idx, 1000) == 0 do
      IO.puts("  #{next_idx}/#{total}  ok=#{ok} err=#{err} skipped=#{skipped}")
    end

    # Snapshot rows with neither chain_sku nor ean produce a nil
    # identifiers_key, which would collide on the unique index. Skip.
    [_chain, chain_sku, _cpid, ean | _] = row

    cond do
      blank?.(chain_sku) and blank?.(ean) ->
        {ok, err, skipped + 1, next_idx}

      true ->
        case import_row.(row) do
          :ok -> {ok + 1, err, skipped, next_idx}
          {:error, cs} ->
            if err < 5, do: IO.inspect(cs, label: "  changeset error")
            {ok, err + 1, skipped, next_idx}
        end
    end
  end)

:ok = Exqlite.Sqlite3.release(conn, stmt)
:ok = Exqlite.Sqlite3.close(conn)

IO.puts("\nDone. processed=#{idx} ok=#{ok} err=#{err} skipped=#{skipped}")

# Side-by-side viewer for one chain category — what's in it, what
# it might be, what to type into the checklist.
#
#   mix run priv/repo/seeds/review.exs <chain> <slug>
#
# Prints:
#   - the category's path + listing count
#   - 7 random sample listings
#   - top-5 unified-subcategory candidates ranked by Jaro similarity

alias SuperBarato.Catalog.{AppCategory, AppSubcategory, ChainCategory}
alias SuperBarato.Repo
import Ecto.Query

case System.argv() do
  [chain, slug | _] ->
    cc = Repo.one(from c in ChainCategory, where: c.chain == ^chain and c.slug == ^slug)

    unless cc do
      IO.puts("no chain_category for chain=#{chain}, slug=#{slug}")
      System.halt(1)
    end

    walk = fn cat, walk ->
      case cat do
        %ChainCategory{parent_slug: nil, name: n} ->
          n

        %ChainCategory{parent_slug: ps, name: n} ->
          parent =
            Repo.one(from p in ChainCategory, where: p.chain == ^chain and p.slug == ^ps)

          case parent do
            nil -> n
            p -> walk.(p, walk) <> " / " <> n
          end
      end
    end

    full_path = walk.(cc, walk)

    {:ok, %{rows: [[count]]}} =
      Repo.query(
        """
        SELECT COUNT(*)
        FROM chain_listing_categories clc
        JOIN chain_categories cc ON cc.id = clc.chain_category_id
        WHERE cc.chain = ? AND cc.slug = ?
        """,
        [chain, slug]
      )

    IO.puts("=== #{chain} ===")
    IO.puts("path:   #{full_path}")
    IO.puts("slug:   #{slug}")
    IO.puts("count:  #{count}")
    IO.puts("")

    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT cl.brand, cl.name, cl.current_regular_price, cl.chain_sku, cl.pdp_url
        FROM chain_listings cl
        JOIN chain_listing_categories clc ON clc.chain_listing_id = cl.id
        JOIN chain_categories cc ON cc.id = clc.chain_category_id
        WHERE cc.chain = ? AND cc.slug = ?
        ORDER BY RANDOM() LIMIT 7
        """,
        [chain, slug]
      )

    IO.puts("Sample listings:")

    if rows == [] do
      IO.puts("  (none)")
    else
      for [brand, name, price, sku, url] <- rows do
        IO.puts("  #{brand || "?"} — #{name}")
        IO.puts("    $#{price || 0}  (sku #{sku})")
        IO.puts("    #{url}")
      end
    end

    subs =
      Repo.all(
        from s in AppSubcategory,
          join: c in AppCategory,
          on: c.id == s.app_category_id,
          select: %{
            cat_slug: c.slug,
            sub_slug: s.slug,
            sub_name: s.name,
            cat_name: c.name
          }
      )

    leaf = String.downcase(cc.name)

    ranked =
      subs
      |> Enum.map(fn s ->
        d_sub = String.jaro_distance(leaf, String.downcase(s.sub_name))
        d_cat = String.jaro_distance(leaf, String.downcase(s.cat_name))
        {s, max(d_sub, d_cat * 0.9)}
      end)
      |> Enum.sort_by(fn {_, d} -> -d end)
      |> Enum.take(5)

    IO.puts("\nTop-5 candidates:")

    for {s, d} <- ranked do
      score = :io_lib.format("~.3f", [d]) |> IO.iodata_to_binary()
      IO.puts("  [#{score}]  #{s.cat_slug}/#{s.sub_slug}  (#{s.cat_name} / #{s.sub_name})")
    end

    IO.puts("\nTo mark as the top match, paste this into priv/repo/seeds/categories/#{chain}.txt:")

    {top, _} = hd(ranked)

    IO.puts(~s/[x]: {category: "#{top.cat_slug}", subcategory: "#{top.sub_slug}"}/)

  _ ->
    IO.puts("usage: mix run priv/repo/seeds/review.exs <chain> <slug>")
    System.halt(1)
end

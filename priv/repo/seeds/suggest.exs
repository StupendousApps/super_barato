# Auto-map obvious [ ] entries by name similarity.
#
#   mix run priv/repo/seeds/suggest.exs
#   mix run priv/repo/seeds/suggest.exs --threshold 0.95
#   mix run priv/repo/seeds/suggest.exs --dry-run
#
# Strategy: for each unchecked entry, pick the AppSubcategory whose
# name has the highest Jaro distance to the chain category's leaf
# name. If above the threshold, rewrite [ ] → [x]. Otherwise leave.
# Idempotent — re-running adds no entries once everything obvious is
# mapped.

alias SuperBarato.Catalog.{AppCategory, AppSubcategory, CategoryChecklist}
alias SuperBarato.Repo
import Ecto.Query

{opts, _, _} =
  OptionParser.parse(System.argv(),
    strict: [threshold: :float, dry_run: :boolean],
    aliases: [t: :threshold]
  )

threshold = opts[:threshold] || 0.92
dry? = opts[:dry_run] == true

subs_db =
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

# Pull keyword lists from the JSONL — one source of truth, no need to
# extend the DB schema for what's a single-shot triage helper.
jsonl_path = Path.expand("categories.jsonl", __DIR__)

keywords_by_pair =
  if File.exists?(jsonl_path) do
    jsonl_path
    |> File.stream!()
    |> Stream.map(&Jason.decode!/1)
    |> Stream.filter(&(&1["kind"] == "subcategory"))
    |> Enum.reduce(%{}, fn r, acc ->
      Map.put(acc, {r["category_slug"], r["slug"]}, r["keywords"] || [])
    end)
  else
    %{}
  end

subs =
  Enum.map(subs_db, fn s ->
    Map.put(s, :keywords, Map.get(keywords_by_pair, {s.cat_slug, s.sub_slug}, []))
  end)

# Best-match: max of
#   d(leaf, sub_name),
#   0.9 * d(leaf, cat_name),     — dampened so a leaf matching the
#                                   category root doesn't outrank a
#                                   real subcategory match,
#   d(leaf, kw)  for kw <- sub.keywords  — full weight; keywords are
#                                   curated synonyms / spelling
#                                   variants explicitly added to
#                                   improve matching.
score = fn leaf ->
  l = String.downcase(leaf)

  Enum.max_by(
    Enum.map(subs, fn s ->
      d_sub = String.jaro_distance(l, String.downcase(s.sub_name))
      d_cat = String.jaro_distance(l, String.downcase(s.cat_name))

      d_kw =
        s.keywords
        |> Enum.map(&String.jaro_distance(l, String.downcase(&1)))
        |> Enum.max(fn -> 0.0 end)

      {s, Enum.max([d_sub, d_cat * 0.9, d_kw])}
    end),
    fn {_, d} -> d end
  )
end

leaf_of = fn path -> path |> String.split(" / ") |> List.last() end

dir = Path.expand("categories", __DIR__)
chains = ~w(jumbo santa_isabel lider tottus unimarc acuenta)

for chain <- chains do
  path = Path.join(dir, "#{chain}.txt")

  cond do
    not File.exists?(path) ->
      IO.puts("skip #{chain} (no file)")

    true ->
      entries = CategoryChecklist.parse_file(path)

      {new_entries, hits} =
        Enum.map_reduce(entries, [], fn e, hits ->
          case e.status do
            :unchecked ->
              {best, dist} = score.(leaf_of.(e.path))

              if dist >= threshold do
                hit = {e.path, best.cat_slug, best.sub_slug, dist}

                {%{
                   e
                   | status: :mapped,
                     mapping: %{category: best.cat_slug, subcategory: best.sub_slug}
                 }, [hit | hits]}
              else
                {e, hits}
              end

            _ ->
              {e, hits}
          end
        end)

      n = length(hits)

      cond do
        n == 0 ->
          IO.puts("#{chain}: no matches above #{threshold}")

        dry? ->
          IO.puts("#{chain}: #{n} would match (dry run)")

          for {p, c, s, d} <- Enum.reverse(hits) do
            IO.puts("  [#{:io_lib.format("~.3f", [d]) |> IO.iodata_to_binary()}] #{p} -> #{c}/#{s}")
          end

        true ->
          CategoryChecklist.write_file!(path, new_entries)
          IO.puts("#{chain}: #{n} entries auto-mapped")
      end
  end
end

unless dry? do
  Code.eval_file(Path.expand("sync_yaml.exs", __DIR__))
end

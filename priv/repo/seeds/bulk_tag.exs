# Sweep [ ] entries matching a path pattern and mark them all the
# same way.
#
#   mix run priv/repo/seeds/bulk_tag.exs <chain> \
#     --path-contains "Yoghurt" \
#     --to lacteos-y-refrigerados/yoghurt
#
#   mix run priv/repo/seeds/bulk_tag.exs lider \
#     --path-contains "Cerveza" \
#     --to licores/cervezas \
#     --dry-run
#
# `--path-contains` is a case-insensitive substring match against the
# entry's full ancestry path. `--to` is `<app-category-slug>/<app-
# subcategory-slug>`. Add `--dry-run` to preview without writing.

alias SuperBarato.Catalog.CategoryChecklist

{opts, args, _} =
  OptionParser.parse(System.argv(),
    strict: [path_contains: :string, to: :string, dry_run: :boolean],
    aliases: [d: :dry_run]
  )

chain =
  case args do
    [chain | _] -> chain
    [] -> raise "usage: bulk_tag.exs <chain> --path-contains ... --to cat/sub"
  end

substr = opts[:path_contains] || raise "--path-contains required"
to = opts[:to] || raise "--to required"
dry? = opts[:dry_run] == true

[cat_slug, sub_slug] =
  case String.split(to, "/", parts: 2) do
    [c, s] when c != "" and s != "" -> [c, s]
    _ -> raise "--to must be `<category-slug>/<subcategory-slug>`"
  end

file = Path.expand("categories/#{chain}.txt", __DIR__)

unless File.exists?(file) do
  raise "no such checklist: #{file}"
end

entries = CategoryChecklist.parse_file(file)
needle = String.downcase(substr)

matches =
  Enum.filter(entries, fn e ->
    e.status == :unchecked and String.contains?(String.downcase(e.path), needle)
  end)

IO.puts("#{length(matches)} matching unchecked entries in #{chain}:")

for m <- matches do
  IO.puts("  #{m.path}")
end

cond do
  matches == [] ->
    :ok

  dry? ->
    IO.puts("(dry run — no changes written)")

  true ->
    new =
      Enum.map(entries, fn e ->
        if e.status == :unchecked and String.contains?(String.downcase(e.path), needle) do
          %{e | status: :mapped, mapping: %{category: cat_slug, subcategory: sub_slug}}
        else
          e
        end
      end)

    CategoryChecklist.write_file!(file, new)
    IO.puts("Wrote #{length(matches)} mappings to #{cat_slug}/#{sub_slug}")
end

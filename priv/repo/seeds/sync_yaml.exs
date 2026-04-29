# Rebuild priv/repo/seeds/categories.yaml + categories.jsonl from
# the .txt checklists.
#
#   mix run priv/repo/seeds/sync_yaml.exs
#
# Three things happen:
#   1. Compute an `id` (8-char sha256 prefix of name) for every
#      category and subcategory and emit it into the YAML.
#   2. Regenerate the `chains:` blocks under each subcategory from
#      the per-chain checklists. Subcategories with no mappings yet
#      are written without a `chains:` key.
#   3. Emit a flattened priv/repo/seeds/categories.jsonl with one
#      record per category and one per subcategory, suitable for
#      grep / fzf during triage.
#
# The taxonomy itself (categories + subcategories + their slugs/names)
# and the leading comment header are preserved verbatim.

alias SuperBarato.Catalog.CategoryChecklist

dir = Path.expand("categories", __DIR__)
yaml_path = Path.expand("categories.yaml", __DIR__)
jsonl_path = Path.expand("categories.jsonl", __DIR__)
chains = ~w(jumbo santa_isabel lider tottus unimarc acuenta)

# Stable 8-char id derived from the node's full ancestry path
# ("Frutas y Verduras" for a category, "Congelados / Pollo" for a
# subcategory). Hashing the path — not just the name — lets two
# different subcategories share a leaf name (e.g. "Pollo" lives in
# both Carnes y Pescados and Congelados) without colliding ids.
# Renaming a node intentionally changes its id; downstream references
# (checklists, DB rows) must be migrated alongside.
hash_id = fn path ->
  :crypto.hash(:sha256, path) |> binary_part(0, 4) |> Base.encode16(case: :lower)
end

# 1. Build {cat_slug, sub_slug} → %{chain => [chain_slug, ...]} from
#    the checklists. Ordering inside each chain list mirrors checklist
#    file order so the YAML diff is deterministic.
mappings =
  Enum.reduce(chains, %{}, fn chain, acc ->
    path = Path.join(dir, "#{chain}.txt")

    if File.exists?(path) do
      path
      |> CategoryChecklist.parse_file()
      |> Enum.filter(&(&1.status == :mapped))
      |> Enum.reduce(acc, fn e, a ->
        key = {e.mapping.category, e.mapping.subcategory}
        chain_map = Map.get(a, key, %{})
        slugs = Map.get(chain_map, chain, []) ++ [e.slug]
        Map.put(a, key, Map.put(chain_map, chain, slugs))
      end)
    else
      acc
    end
  end)

# 2. Parse the existing YAML into a structured list (same shape as
#    seed_app_categories.exs). Lines that are pure header comments
#    above the first `- name:` are preserved verbatim.
raw = File.read!(yaml_path)
{header, body} = String.split(raw, ~r/^(?=- name: )/m, parts: 2) |> case do
  [h, b] -> {h, b}
  [b] -> {"", b}
end

parse_yaml = fn body ->
  lines =
    body
    |> String.split("\n")
    |> Enum.reject(fn line ->
      stripped = String.trim_leading(line)
      stripped == "" or String.starts_with?(stripped, "#")
    end)

  {cats, current} =
    Enum.reduce(lines, {[], nil}, fn line, {cats, current} ->
      cond do
        String.starts_with?(line, "- name: ") ->
          name = String.trim_trailing(String.replace_prefix(line, "- name: ", ""))
          new_cats = if current, do: cats ++ [current], else: cats
          {new_cats, %{name: name, slug: nil, subs: []}}

        String.starts_with?(line, "  slug: ") and current ->
          slug = String.trim_trailing(String.replace_prefix(line, "  slug: ", ""))
          {cats, %{current | slug: slug}}

        String.starts_with?(line, "    - name: ") and current ->
          name = String.trim_trailing(String.replace_prefix(line, "    - name: ", ""))
          {cats, %{current | subs: current.subs ++ [%{name: name, slug: nil}]}}

        String.starts_with?(line, "      slug: ") and current ->
          slug = String.trim_trailing(String.replace_prefix(line, "      slug: ", ""))
          {last, rest} = List.pop_at(current.subs, -1)
          {cats, %{current | subs: rest ++ [%{last | slug: slug}]}}

        true ->
          {cats, current}
      end
    end)

  if current, do: cats ++ [current], else: cats
end

categories = parse_yaml.(body)

# 3. Re-serialize.
serialize_chains = fn chain_map ->
  # Stable chain order (alphabetical) for diff sanity.
  chains_in_order = Enum.sort(Map.keys(chain_map))

  Enum.map(chains_in_order, fn chain ->
    slugs = Map.get(chain_map, chain, [])

    [
      "        #{chain}:\n"
      | Enum.map(slugs, fn s -> "          - #{s}\n" end)
    ]
  end)
end

serialize_sub = fn cat, sub, chain_map ->
  path = cat.name <> " / " <> sub.name

  base =
    "    - name: #{sub.name}\n" <>
      "      slug: #{sub.slug}\n" <>
      "      id: #{hash_id.(path)}\n"

  case chain_map do
    nil -> base
    _ -> base <> "      chains:\n" <> IO.iodata_to_binary(serialize_chains.(chain_map))
  end
end

serialize_cat = fn cat ->
  header_lines =
    "- name: #{cat.name}\n" <>
      "  slug: #{cat.slug}\n" <>
      "  id: #{hash_id.(cat.name)}\n" <>
      "  subcategories:\n"

  subs_text =
    Enum.map_join(cat.subs, "", fn sub ->
      cm = Map.get(mappings, {cat.slug, sub.slug})
      serialize_sub.(cat, sub, cm)
    end)

  header_lines <> subs_text
end

new_body = Enum.map_join(categories, "\n", serialize_cat) <> "\n"

File.write!(yaml_path, header <> new_body)

# 4. Flat JSONL — one line per category and one per subcategory.
#    Designed for `grep -i <keyword> categories.jsonl` to surface every
#    place a name might match while triaging chain checklists.
jsonl_lines =
  Enum.flat_map(categories, fn cat ->
    cat_id = hash_id.(cat.name)

    cat_line =
      Jason.encode!(%{
        kind: "category",
        id: cat_id,
        name: cat.name,
        slug: cat.slug,
        path: cat.name
      })

    sub_lines =
      Enum.map(cat.subs, fn sub ->
        path = cat.name <> " / " <> sub.name

        Jason.encode!(%{
          kind: "subcategory",
          id: hash_id.(path),
          name: sub.name,
          slug: sub.slug,
          path: path,
          category_id: cat_id,
          category_name: cat.name,
          category_slug: cat.slug
        })
      end)

    [cat_line | sub_lines]
  end)

File.write!(jsonl_path, Enum.join(jsonl_lines, "\n") <> "\n")

# 5. Report.
total = mappings |> Map.values() |> Enum.flat_map(&Map.values/1) |> Enum.flat_map(& &1) |> length()
subs_with_data = map_size(mappings)

IO.puts(
  "Wrote #{yaml_path}: #{total} chain mappings spread across #{subs_with_data} subcategories."
)

IO.puts("Wrote #{jsonl_path}: #{length(jsonl_lines)} flattened records.")

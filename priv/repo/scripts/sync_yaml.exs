# Rebuild priv/repo/source/categories.yaml + categories.jsonl from
# the .txt checklists.
#
#   mix run priv/repo/scripts/sync_yaml.exs
#
# Three things happen:
#   1. Compute an `id` (8-char sha256 prefix of name) for every
#      category and subcategory and emit it into the YAML.
#   2. Regenerate the `chains:` blocks under each subcategory from
#      the per-chain checklists. Subcategories with no mappings yet
#      are written without a `chains:` key.
#   3. Emit a flattened priv/repo/source/categories.jsonl with one
#      record per category and one per subcategory, suitable for
#      grep / fzf during triage.
#
# The taxonomy itself (categories + subcategories + their slugs/names)
# and the leading comment header are preserved verbatim.

alias SuperBarato.Catalog.CategoryChecklist

dir = Path.expand("categories", __DIR__)
yaml_path = Path.expand("../source/categories.yaml", __DIR__)
jsonl_path = Path.expand("../source/categories.jsonl", __DIR__)
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

# 1. Build a lookup of id → {cat_slug, sub_slug} from the existing
#    JSONL (if present). Used to resolve the `[x]: <id>` entries in
#    the checklists into (category, subcategory) pairs.
id_to_pair =
  case File.read(jsonl_path) do
    {:ok, body} ->
      body
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["kind"] == "subcategory"))
      |> Map.new(fn r -> {r["id"], {r["category_slug"], r["slug"]}} end)

    {:error, _} ->
      %{}
  end

# 2. Build {cat_slug, sub_slug} → %{chain => [chain_slug, ...]} from
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
        case Map.get(id_to_pair, e.mapping.id) do
          nil ->
            IO.puts(
              :stderr,
              "warning: [#{chain}] #{e.path} -> id #{e.mapping.id} not in JSONL; skipping"
            )

            a

          {cat_slug, sub_slug} ->
            key = {cat_slug, sub_slug}
            chain_map = Map.get(a, key, %{})
            slugs = Map.get(chain_map, chain, []) ++ [e.slug]
            Map.put(a, key, Map.put(chain_map, chain, slugs))
        end
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

  # State machine carries `mode` to know whether `        - <item>`
  # lines belong to a `keywords:` block (collected) or a `chains:`
  # block (ignored — chains: is regenerated from scratch).
  {cats, current, _mode} =
    Enum.reduce(lines, {[], nil, :none}, fn line, {cats, current, mode} ->
      cond do
        String.starts_with?(line, "- name: ") ->
          name = String.trim_trailing(String.replace_prefix(line, "- name: ", ""))
          new_cats = if current, do: cats ++ [current], else: cats
          {new_cats, %{name: name, slug: nil, subs: []}, :none}

        String.starts_with?(line, "  slug: ") and current ->
          slug = String.trim_trailing(String.replace_prefix(line, "  slug: ", ""))
          {cats, %{current | slug: slug}, :none}

        String.starts_with?(line, "    - name: ") and current ->
          name = String.trim_trailing(String.replace_prefix(line, "    - name: ", ""))
          sub = %{name: name, slug: nil, keywords: []}
          {cats, %{current | subs: current.subs ++ [sub]}, :none}

        String.starts_with?(line, "      slug: ") and current ->
          slug = String.trim_trailing(String.replace_prefix(line, "      slug: ", ""))
          {last, rest} = List.pop_at(current.subs, -1)
          {cats, %{current | subs: rest ++ [%{last | slug: slug}]}, :none}

        # Inline form: `      keywords: [a, b, c]`
        String.starts_with?(line, "      keywords: [") and current ->
          inner =
            line
            |> String.replace_prefix("      keywords: [", "")
            |> String.trim_trailing()
            |> String.trim_trailing("]")

          kws =
            cond do
              # Quoted form: extract everything between matching quotes.
              # Handles commas inside values (e.g. "0,0%").
              String.contains?(inner, ~s/"/) ->
                ~r/"([^"]*)"/
                |> Regex.scan(inner, capture: :all_but_first)
                |> Enum.flat_map(& &1)

              # Unquoted form: comma-split.
              true ->
                inner
                |> String.split(",")
                |> Enum.map(&String.trim/1)
                |> Enum.reject(&(&1 == ""))
            end

          {last, rest} = List.pop_at(current.subs, -1)
          {cats, %{current | subs: rest ++ [%{last | keywords: last.keywords ++ kws}]}, :none}

        # Block form: `      keywords:` followed by `        - kw` lines
        line == "      keywords:" and current ->
          {cats, current, :keywords}

        line == "      chains:" and current ->
          {cats, current, :chains}

        String.starts_with?(line, "        - ") and mode == :keywords and current ->
          kw = String.trim_trailing(String.replace_prefix(line, "        - ", ""))
          {last, rest} = List.pop_at(current.subs, -1)
          {cats, %{current | subs: rest ++ [%{last | keywords: last.keywords ++ [kw]}]}, mode}

        true ->
          {cats, current, mode}
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

  keywords =
    case sub[:keywords] || [] do
      [] -> ""
      list -> "      keywords: [#{Enum.map_join(list, ", ", &~s/"#{&1}"/)}]\n"
    end

  chains_block =
    case chain_map do
      nil -> ""
      _ -> "      chains:\n" <> IO.iodata_to_binary(serialize_chains.(chain_map))
    end

  base <> keywords <> chains_block
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
        kws = sub[:keywords] || []

        search_text =
          [sub.name, path, sub.slug, cat.name | kws]
          |> Enum.join(" ")
          |> String.downcase()
          |> :unicode.characters_to_nfd_binary()
          |> String.replace(~r/\p{Mn}/u, "")

        Jason.encode!(%{
          kind: "subcategory",
          id: hash_id.(path),
          name: sub.name,
          slug: sub.slug,
          path: path,
          keywords: kws,
          category_id: cat_id,
          category_name: cat.name,
          category_slug: cat.slug,
          search: search_text
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

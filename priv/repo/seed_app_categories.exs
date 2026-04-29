# Seed app_categories + app_subcategories from
# priv/repo/source/categories.yaml. Idempotent: re-running upserts by
# slug, refreshing position from the YAML order.
#
# Run as part of the seeds.exs orchestrator (preferred) or directly:
#   mix run priv/repo/seeds/app_categories.exs

alias SuperBarato.Catalog.{AppCategory, AppSubcategory}
alias SuperBarato.Repo

# Hand-rolled parser for the well-known shape of categories.yaml:
#
#   - name: <name>
#     slug: <slug>
#     subcategories:
#       - name: <name>
#         slug: <slug>
#       ...
parse_yaml = fn path ->
  lines =
    path
    |> File.read!()
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

yaml_path = Path.expand("source/categories.yaml", __DIR__)
categories = parse_yaml.(yaml_path)
now = DateTime.utc_now() |> DateTime.truncate(:second)

{cats_n, subs_n} =
  Enum.reduce(Enum.with_index(categories), {0, 0}, fn {cat, idx}, {cn, sn} ->
    {:ok, app_cat} =
      Repo.insert(
        %AppCategory{
          slug: cat.slug,
          name: cat.name,
          position: idx,
          inserted_at: now,
          updated_at: now
        },
        on_conflict: {:replace, [:name, :position, :updated_at]},
        conflict_target: [:slug],
        returning: true
      )

    sub_n =
      cat.subs
      |> Enum.with_index()
      |> Enum.reduce(0, fn {sub, sidx}, acc ->
        {:ok, _} =
          Repo.insert(
            %AppSubcategory{
              slug: sub.slug,
              name: sub.name,
              position: sidx,
              app_category_id: app_cat.id,
              inserted_at: now,
              updated_at: now
            },
            on_conflict: {:replace, [:name, :position, :app_category_id, :updated_at]},
            conflict_target: [:app_category_id, :slug],
            returning: false
          )

        acc + 1
      end)

    {cn + 1, sn + sub_n}
  end)

IO.puts("Seeded #{cats_n} app_categories, #{subs_n} app_subcategories")

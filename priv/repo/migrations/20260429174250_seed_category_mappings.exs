defmodule SuperBarato.Repo.Migrations.SeedCategoryMappings do
  use Ecto.Migration

  # One-shot data migration. Read priv/repo/seeds/categories.yaml and
  # populate `category_mappings` from every `chains:` block under each
  # subcategory.
  #
  # The YAML's chain entries are slugs of `chain_categories` rows
  # (matched by (chain, slug)). Each subcategory has a stable id that
  # maps 1:1 to an `app_subcategories` row created by
  # priv/repo/seeds/seed_app_categories.exs.
  #
  # Idempotent: existing (chain_category_id) rows are left untouched
  # via `INSERT OR IGNORE` (the unique index on chain_category_id
  # enforces "at most one app_subcategory per chain_category").

  @yaml_path "priv/repo/seeds/categories.yaml"

  def up do
    mappings = parse_yaml(@yaml_path)

    chain_cat_ids = load_chain_categories()
    app_sub_ids = load_app_subcategories()

    {inserted, missing_chain, missing_app} =
      Enum.reduce(mappings, {0, 0, 0}, fn {chain, chain_slug, cat_slug, sub_slug},
                                          {ins, mc, ma} ->
        chain_cat_id = Map.get(chain_cat_ids, {chain, chain_slug})
        app_sub_id = Map.get(app_sub_ids, {cat_slug, sub_slug})

        cond do
          is_nil(chain_cat_id) ->
            {ins, mc + 1, ma}

          is_nil(app_sub_id) ->
            {ins, mc, ma + 1}

          true ->
            now =
              DateTime.utc_now()
              |> DateTime.truncate(:second)
              |> DateTime.to_iso8601()

            repo().query!(
              """
              INSERT OR IGNORE INTO category_mappings
                (chain_category_id, app_subcategory_id, inserted_at, updated_at)
              VALUES (?1, ?2, ?3, ?3)
              """,
              [chain_cat_id, app_sub_id, now]
            )

            {ins + 1, mc, ma}
        end
      end)

    IO.puts(
      "[seed_category_mappings] inserted=#{inserted} " <>
        "missing_chain_category=#{missing_chain} " <>
        "missing_app_subcategory=#{missing_app}"
    )
  end

  def down do
    repo().query!("DELETE FROM category_mappings")
  end

  # === YAML parsing =========================================================
  #
  # Same shape as priv/repo/seeds/seed_app_categories.exs, extended to
  # also pick up the per-chain slug list under each subcategory.

  defp parse_yaml(path) do
    lines =
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(fn line ->
        stripped = String.trim_leading(line)
        stripped == "" or String.starts_with?(stripped, "#")
      end)

    {acc, _state} = Enum.reduce(lines, {[], initial_state()}, &reduce_line/2)
    Enum.reverse(acc)
  end

  defp initial_state do
    %{cat_slug: nil, sub_slug: nil, chain: nil}
  end

  defp reduce_line(line, {acc, state}) do
    cond do
      String.starts_with?(line, "- name: ") ->
        {acc, %{state | cat_slug: nil, sub_slug: nil, chain: nil}}

      String.starts_with?(line, "  slug: ") ->
        slug = String.trim_trailing(String.replace_prefix(line, "  slug: ", ""))
        {acc, %{state | cat_slug: slug, sub_slug: nil, chain: nil}}

      String.starts_with?(line, "    - name: ") ->
        {acc, %{state | sub_slug: nil, chain: nil}}

      String.starts_with?(line, "      slug: ") ->
        slug = String.trim_trailing(String.replace_prefix(line, "      slug: ", ""))
        {acc, %{state | sub_slug: slug, chain: nil}}

      String.starts_with?(line, "        ") and String.ends_with?(line, ":") ->
        chain =
          line
          |> String.trim()
          |> String.trim_trailing(":")

        {acc, %{state | chain: chain}}

      String.starts_with?(line, "          - ") and not is_nil(state.chain) ->
        chain_slug = String.trim_trailing(String.replace_prefix(line, "          - ", ""))
        {[{state.chain, chain_slug, state.cat_slug, state.sub_slug} | acc], state}

      true ->
        {acc, state}
    end
  end

  # === DB lookups ===========================================================

  defp load_chain_categories do
    {:ok, %{rows: rows}} = repo().query("SELECT id, chain, slug FROM chain_categories")
    Map.new(rows, fn [id, chain, slug] -> {{chain, slug}, id} end)
  end

  defp load_app_subcategories do
    {:ok, %{rows: rows}} =
      repo().query("""
      SELECT s.id, c.slug, s.slug
      FROM app_subcategories s
      JOIN app_categories c ON c.id = s.app_category_id
      """)

    Map.new(rows, fn [id, cat_slug, sub_slug] -> {{cat_slug, sub_slug}, id} end)
  end
end

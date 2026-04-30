defmodule SuperBarato.Catalog.CategoryMappingTest do
  @moduledoc """
  Data-integrity coverage for the chain_category → app_subcategory
  pipeline. Three things matter and are exercised here:

    1. `sync_listing_categories` (driven from `Catalog.upsert_listing`)
       writes a `chain_listing_categories` join row only for paths that
       resolve to a real `chain_categories` slug. Unknown slugs are
       silently dropped — that's how a chain category with no
       `category_mappings` row stays uncategorized end-to-end.

    2. `Catalog.categories_by_product_ids/1` returns nothing for a
       product whose listings carry chain categories that have no
       mapping yet. When mappings exist, the consensus categorization
       (most-frequent across the product's listings) wins.

    3. The manual override on `products.app_subcategory_id` wins over
       the listing-derived consensus.
  """

  use SuperBarato.DataCase, async: false

  alias SuperBarato.{Catalog, Linker, Repo}

  alias SuperBarato.Catalog.{
    AppCategory,
    AppSubcategory,
    CategoryMapping,
    ChainListingCategory,
    Product
  }

  alias SuperBarato.Crawler.ChainCategory, as: CrawlerCategory
  alias SuperBarato.Crawler.Listing

  defp insert_chain_category!(chain, slug, opts \\ []) do
    cat = %CrawlerCategory{
      chain: chain,
      slug: slug,
      name: opts[:name] || slug,
      parent_slug: opts[:parent_slug],
      level: opts[:level] || 1,
      is_leaf: Keyword.get(opts, :is_leaf, true)
    }

    {:ok, row} = Catalog.upsert_category(cat)
    row
  end

  defp insert_app_taxonomy!(cat_slug, sub_slug) do
    {:ok, cat} =
      %AppCategory{}
      |> AppCategory.changeset(%{
        slug: cat_slug,
        name: cat_slug,
        position: 0
      })
      |> Repo.insert()

    {:ok, sub} =
      %AppSubcategory{}
      |> AppSubcategory.changeset(%{
        slug: sub_slug,
        name: sub_slug,
        position: 0,
        app_category_id: cat.id
      })
      |> Repo.insert()

    %{cat: cat, sub: sub}
  end

  defp map_chain_category_to_subcategory!(chain_category, sub) do
    %CategoryMapping{}
    |> Ecto.Changeset.cast(
      %{chain_category_id: chain_category.id, app_subcategory_id: sub.id},
      [:chain_category_id, :app_subcategory_id]
    )
    |> Repo.insert!()
  end

  defp upsert_listing!(opts) do
    l = %Listing{
      chain: opts[:chain] || :unimarc,
      chain_sku: opts[:chain_sku] || "sku-#{System.unique_integer([:positive])}",
      ean: opts[:ean],
      identifiers_key: opts[:identifiers_key] || "k-#{System.unique_integer([:positive])}",
      name: opts[:name] || "Test",
      brand: opts[:brand],
      image_url: nil,
      pdp_url: nil,
      category_path: opts[:category_path],
      regular_price: Keyword.get(opts, :regular_price, 1990),
      promo_price: nil,
      promotions: %{},
      raw: %{}
    }

    {:ok, _action, row} = Catalog.upsert_listing(l)
    row
  end

  # Run the linker synchronously so the test has a Product reachable
  # from the listing without depending on the GenServer's mailbox.
  defp link_synchronously!(listing_id) do
    listing = Repo.get!(SuperBarato.Catalog.ChainListing, listing_id)

    Repo.transaction(fn ->
      {_action, product, source} =
        Linker.find_or_create_product_for_listing(listing)

      Linker.set_listing_link(product.id, listing.id,
        source: source,
        confidence: 1.0,
        linked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      product
    end)
    |> case do
      {:ok, p} -> p
    end
  end

  describe "sync_listing_categories (via upsert_listing)" do
    test "writes a chain_listing_categories row when the path resolves" do
      insert_chain_category!(:unimarc, "despensa")

      row =
        upsert_listing!(
          chain: :unimarc,
          identifiers_key: "k1",
          category_path: "despensa"
        )

      joins =
        Repo.all(
          from clc in ChainListingCategory,
            where: clc.chain_listing_id == ^row.id
        )

      assert length(joins) == 1
    end

    test "drops paths that do not match any chain_category" do
      # Note: no chain_category with this slug.
      row =
        upsert_listing!(
          chain: :unimarc,
          identifiers_key: "k2",
          category_path: "ghost-category"
        )

      # The listing keeps the legacy fallback array...
      assert row.category_paths == ["ghost-category"]

      # ...but no join row was written.
      joins =
        Repo.all(
          from clc in ChainListingCategory,
            where: clc.chain_listing_id == ^row.id
        )

      assert joins == []
    end

    test "is idempotent on re-upsert with the same slug" do
      insert_chain_category!(:unimarc, "lacteos")

      row1 =
        upsert_listing!(
          chain: :unimarc,
          identifiers_key: "k3",
          category_path: "lacteos"
        )

      _row2 =
        upsert_listing!(
          chain: :unimarc,
          identifiers_key: "k3",
          category_path: "lacteos"
        )

      joins =
        Repo.all(
          from clc in ChainListingCategory,
            where: clc.chain_listing_id == ^row1.id
        )

      assert length(joins) == 1
    end
  end

  describe "categories_by_product_ids/1 — no-mapping behavior" do
    test "returns nothing for a product whose chain_category has no category_mapping" do
      insert_chain_category!(:unimarc, "no-mapping-yet")

      listing =
        upsert_listing!(
          chain: :unimarc,
          identifiers_key: "ean=7800000000001",
          ean: "7800000000001",
          category_path: "no-mapping-yet"
        )

      product = link_synchronously!(listing.id)

      assert Catalog.categories_by_product_ids([product.id]) == %{}
    end

    test "returns the mapped subcategory when a category_mapping exists" do
      cat = insert_chain_category!(:unimarc, "frutas")
      %{sub: sub, cat: app_cat} = insert_app_taxonomy!("frutas-y-verduras", "frutas")
      map_chain_category_to_subcategory!(cat, sub)

      listing =
        upsert_listing!(
          chain: :unimarc,
          identifiers_key: "ean=7800000000002",
          ean: "7800000000002",
          category_path: "frutas"
        )

      product = link_synchronously!(listing.id)

      result = Catalog.categories_by_product_ids([product.id])
      entry = Map.fetch!(result, product.id)

      assert entry.cat_slug == app_cat.slug
      assert entry.sub_slug == sub.slug
    end
  end

  describe "categories_by_product_ids/1 — manual override" do
    test "products.app_subcategory_id wins over the consensus categorization" do
      # Wire up two mappings: the consensus (from listings) points at
      # subcategory A, while the manual override points at B. Override
      # should win.
      cat_a = insert_chain_category!(:unimarc, "lacteos-cat")
      %{sub: sub_a, cat: app_cat_a} = insert_app_taxonomy!("lacteos-y-refrigerados", "leches")
      map_chain_category_to_subcategory!(cat_a, sub_a)

      %{sub: sub_b, cat: app_cat_b} = insert_app_taxonomy!("snacks", "snacks-salados")

      listing =
        upsert_listing!(
          chain: :unimarc,
          identifiers_key: "ean=7800000000003",
          ean: "7800000000003",
          category_path: "lacteos-cat"
        )

      product = link_synchronously!(listing.id)

      # Without the override, the consensus picks A.
      consensus = Catalog.categories_by_product_ids([product.id])
      assert consensus[product.id].sub_slug == sub_a.slug

      # Apply the manual override → B wins.
      product
      |> Product.changeset(%{app_subcategory_id: sub_b.id})
      |> Repo.update!()

      overridden = Catalog.categories_by_product_ids([product.id])
      assert overridden[product.id].sub_slug == sub_b.slug
      assert overridden[product.id].cat_slug == app_cat_b.slug

      # Sanity: the unrelated category list shouldn't matter.
      assert app_cat_a.slug != app_cat_b.slug
    end
  end
end

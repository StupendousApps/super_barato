defmodule SuperBarato.LinkerTest do
  use SuperBarato.DataCase, async: false

  alias SuperBarato.{Catalog, Linker, Repo}
  alias SuperBarato.Catalog.{ChainListing, Product, ProductIdentifier}
  alias SuperBarato.Crawler.Listing
  alias SuperBarato.Linker.ProductListing

  defp insert_product!(attrs \\ %{}) do
    base = %{canonical_name: "Test Product", brand: nil, image_url: nil}
    %Product{} |> Product.changeset(Map.merge(base, attrs)) |> Repo.insert!()
  end

  defp insert_listing!(chain, sku) do
    {:ok, _action, row} =
      Catalog.upsert_listing(%Listing{
        chain: chain,
        chain_sku: sku,
        identifiers_key: "sku=#{sku}",
        name: "Listing #{sku}",
        category_path: "test",
        regular_price: 1000
      })

    row
  end

  describe "delete_if_orphan/1" do
    test "drops a product with zero links" do
      p = insert_product!()
      assert Linker.delete_if_orphan(p.id) == :deleted
      refute Repo.get(Product, p.id)
    end

    test "keeps a product with at least one link" do
      p = insert_product!()
      l = insert_listing!(:unimarc, "x-1")
      {:ok, _} = Linker.link(p.id, l.id, source: "test")

      assert Linker.delete_if_orphan(p.id) == :kept
      assert Repo.get(Product, p.id)
    end

    test "is a no-op on a missing id" do
      assert Linker.delete_if_orphan(999_999_999) == :kept
    end

    test "cascades through product_identifiers" do
      p = insert_product!()

      {:ok, _} =
        %ProductIdentifier{}
        |> ProductIdentifier.changeset(%{
          product_id: p.id,
          kind: "ean_13",
          value: "1234567890123"
        })
        |> Repo.insert()

      assert Linker.delete_if_orphan(p.id) == :deleted
      refute Repo.get_by(ProductIdentifier, kind: "ean_13", value: "1234567890123")
    end
  end

  describe "link_admin/2 — orphan cleanup" do
    test "drops the previous product when its last listing moves away" do
      p1 = insert_product!(%{canonical_name: "Old"})
      p2 = insert_product!(%{canonical_name: "New"})
      l = insert_listing!(:unimarc, "y-1")

      {:ok, _} = Linker.link(p1.id, l.id, source: "ean_canonical")

      {:ok, _} = Linker.link_admin(p2.id, l.id)

      refute Repo.get(Product, p1.id), "p1 should be deleted (orphan)"
      assert Repo.get(Product, p2.id)
    end

    test "keeps the previous product when it still has other listings" do
      p1 = insert_product!(%{canonical_name: "Old"})
      p2 = insert_product!(%{canonical_name: "New"})
      l_a = insert_listing!(:unimarc, "z-1")
      l_b = insert_listing!(:lider, "z-2")

      {:ok, _} = Linker.link(p1.id, l_a.id, source: "ean_canonical")
      {:ok, _} = Linker.link(p1.id, l_b.id, source: "ean_canonical")

      {:ok, _} = Linker.link_admin(p2.id, l_a.id)

      assert Repo.get(Product, p1.id), "p1 still has l_b → keep"
    end
  end

  describe "unlink/2 — orphan cleanup" do
    test "drops the product after its last listing is unlinked" do
      p = insert_product!()
      l = insert_listing!(:unimarc, "u-1")
      {:ok, _} = Linker.link(p.id, l.id, source: "ean_canonical")

      assert Linker.unlink(p.id, l.id) == :ok
      refute Repo.get(Product, p.id)
      refute Repo.get_by(ChainListing, id: l.id) == nil
    end

    test "keeps the product when it still has other listings" do
      p = insert_product!()
      l_a = insert_listing!(:unimarc, "u-2")
      l_b = insert_listing!(:lider, "u-3")
      {:ok, _} = Linker.link(p.id, l_a.id, source: "ean_canonical")
      {:ok, _} = Linker.link(p.id, l_b.id, source: "ean_canonical")

      assert Linker.unlink(p.id, l_a.id) == :ok
      assert Repo.get(Product, p.id)
      assert Repo.aggregate(from(pl in ProductListing, where: pl.product_id == ^p.id), :count) == 1
    end

    test "returns :not_found when no link exists" do
      p = insert_product!()
      l = insert_listing!(:unimarc, "u-4")

      assert Linker.unlink(p.id, l.id) == :not_found
      assert Repo.get(Product, p.id), "no-op shouldn't delete unrelated product"
    end
  end
end

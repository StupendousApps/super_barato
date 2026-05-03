defmodule SuperBarato.ThumbnailsTest do
  @moduledoc """
  Covers the app-specific facade only. The library
  (`StupendousThumbnails`) carries its own test suite.
  """
  use SuperBarato.DataCase, async: false

  alias SuperBarato.Catalog.Product
  alias SuperBarato.{Repo, Thumbnails}
  alias StupendousThumbnails.{Image, Variant}
  alias StupendousThumbnails.Transport.Mock

  setup do
    Mock.reset()
    :ok
  end

  defp insert_product!(attrs \\ %{}) do
    %Product{}
    |> Product.changeset(
      Map.merge(
        %{canonical_name: "Test", image_url: "https://cdn.test/p.png"},
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "thumbnail_url/1" do
    test "prefers the embed's variant URL when present" do
      product =
        insert_product!(%{
          image_url: "https://cdn.test/raw.png",
          thumbnail: %{
            variants: [
              %{size: 400, format: "webp", url: "https://thumbs.test/x-400.webp", key: "x-400.webp"}
            ]
          }
        })

      assert Thumbnails.thumbnail_url(product) == "https://thumbs.test/x-400.webp"
    end

    test "falls back to image_url when there's no embed" do
      product = insert_product!(%{image_url: "https://cdn.test/raw.png"})
      assert Thumbnails.thumbnail_url(product) == "https://cdn.test/raw.png"
    end
  end

  describe "ensure/1" do
    test "fetches image_url, generates an Image embed, persists it" do
      product = insert_product!(%{image_url: "https://cdn.test/img.png"})

      assert {:ok, updated} = Thumbnails.ensure(product)
      assert %Image{variants: [%Variant{size: 400, format: "webp", key: key}]} = updated.thumbnail
      assert String.starts_with?(key, "thumbnails/")
      assert String.ends_with?(key, "-400.webp")
    end

    test "no-op when an embed already exists" do
      product =
        insert_product!(%{
          image_url: "https://cdn.test/x.png",
          thumbnail: %{variants: [%{size: 400, format: "webp", url: "u", key: "k"}]}
        })

      assert {:ok, ^product} = Thumbnails.ensure(product)
      assert Mock.gets() == []
    end

    test "no-op when image_url is blank" do
      product = insert_product!(%{image_url: nil})
      assert {:ok, _} = Thumbnails.ensure(product)
      assert Mock.gets() == []
    end

    test "fetch failure leaves the embed alone" do
      Mock.stub_get("https://cdn.test/dead.png", {:error, {:http, 404}})
      product = insert_product!(%{image_url: "https://cdn.test/dead.png"})

      assert {:ok, %Product{thumbnail: nil}} = Thumbnails.ensure(product)
    end
  end

  describe "use_image/2" do
    test "regenerates from the new URL and updates image_url + thumbnail" do
      product =
        insert_product!(%{image_url: "https://cdn.test/old.png"})

      assert {:ok, updated} = Thumbnails.use_image(product, "https://cdn.test/new.png")
      assert updated.image_url == "https://cdn.test/new.png"
      assert %Image{variants: [_]} = updated.thumbnail
    end

    test "deletes old R2 objects no longer referenced" do
      {:ok, product_with_old} =
        insert_product!(%{image_url: "https://cdn.test/old.png"})
        |> Thumbnails.ensure()

      [%Variant{key: old_key}] = product_with_old.thumbnail.variants
      assert Mock.objects() |> Map.has_key?(old_key)

      {:ok, _} = Thumbnails.use_image(product_with_old, "https://cdn.test/new.png")

      # Old object evicted from the bucket.
      refute Mock.objects() |> Map.has_key?(old_key)
    end

    test "keeps old R2 object when another product still references the same key" do
      {:ok, p1} =
        insert_product!(%{
          canonical_name: "P1",
          image_url: "https://cdn.test/shared.png"
        })
        |> Thumbnails.ensure()

      [%Variant{key: shared_key}] = p1.thumbnail.variants

      {:ok, p2} =
        insert_product!(%{
          canonical_name: "P2",
          image_url: "https://cdn.test/shared.png"
        })
        |> Thumbnails.ensure()

      # Both products share the same content-addressed key.
      assert hd(p2.thumbnail.variants).key == shared_key

      {:ok, _} = Thumbnails.use_image(p1, "https://cdn.test/new.png")

      # p2 still references the shared key → must NOT have been deleted.
      assert Mock.objects() |> Map.has_key?(shared_key)
    end
  end
end

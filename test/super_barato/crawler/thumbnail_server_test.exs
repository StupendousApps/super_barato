defmodule SuperBarato.Crawler.ThumbnailServerTest do
  use SuperBarato.DataCase, async: false

  alias SuperBarato.Catalog.{ChainListing, Product}
  alias SuperBarato.Crawler.ThumbnailServer
  alias SuperBarato.Linker.ProductListing
  alias SuperBarato.{Repo, Thumbnails}
  alias StupendousThumbnails.Image
  alias StupendousThumbnails.Transport.Mock, as: MockTransport

  setup do
    MockTransport.reset()
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

  defp insert_listing!(chain, sku, image_url) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %ChainListing{}
    |> ChainListing.discovery_changeset(%{
      chain: to_string(chain),
      chain_sku: sku,
      identifiers_key: "sku=#{sku}",
      name: "L #{sku}",
      image_url: image_url,
      first_seen_at: now,
      last_discovered_at: now,
      last_priced_at: now,
      current_regular_price: 1000,
      active: true,
      has_price: true
    })
    |> Repo.insert!()
  end

  defp link!(product_id, listing_id) do
    %ProductListing{}
    |> ProductListing.changeset(%{
      product_id: product_id,
      chain_listing_id: listing_id,
      source: "single_chain",
      linked_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  describe "enqueue_sync/1" do
    test "happy path: thumbnails the product from its image_url" do
      product = insert_product!(%{image_url: "https://cdn.test/p.png"})

      assert :ok = ThumbnailServer.enqueue_sync(product.id)

      reloaded = Repo.get!(Product, product.id)
      assert %Image{variants: [_ | _]} = reloaded.thumbnail
      assert MockTransport.gets() == ["https://cdn.test/p.png"]
    end

    test "no-op when an embed is already set" do
      product =
        insert_product!(%{
          thumbnail: %{
            variants: [
              %{size: 400, format: "webp", url: "u", key: "k"}
            ]
          }
        })

      assert :skip = ThumbnailServer.enqueue_sync(product.id)
      assert MockTransport.gets() == []
    end

    test "no-op when product doesn't exist" do
      assert :skip = ThumbnailServer.enqueue_sync(99_999_999)
    end

    test "falls through to listing image_urls when product image_url fails" do
      product = insert_product!(%{image_url: "https://cdn.test/broken.png"})
      l1 = insert_listing!(:unimarc, "sku-a", "https://cdn.test/also-broken.png")
      l2 = insert_listing!(:unimarc, "sku-b", "https://cdn.test/works.png")
      link!(product.id, l1.id)
      link!(product.id, l2.id)

      MockTransport.stub_get("https://cdn.test/broken.png", {:error, {:http, 404}})
      MockTransport.stub_get("https://cdn.test/also-broken.png", {:error, {:http, 500}})
      # /works.png falls through to default (1x1 PNG → success)

      assert :ok = ThumbnailServer.enqueue_sync(product.id)

      reloaded = Repo.get!(Product, product.id)
      assert reloaded.image_url == "https://cdn.test/works.png"
      assert %Image{variants: [_ | _]} = reloaded.thumbnail

      # All three URLs were tried in order.
      assert MockTransport.gets() == [
               "https://cdn.test/broken.png",
               "https://cdn.test/also-broken.png",
               "https://cdn.test/works.png"
             ]
    end

    test "returns :error when every candidate fails" do
      product = insert_product!(%{image_url: "https://cdn.test/dead.png"})
      l = insert_listing!(:unimarc, "sku-x", "https://cdn.test/also-dead.png")
      link!(product.id, l.id)

      MockTransport.stub_get("https://cdn.test/dead.png", {:error, :enetunreach})
      MockTransport.stub_get("https://cdn.test/also-dead.png", {:error, :enetunreach})

      assert :error = ThumbnailServer.enqueue_sync(product.id)
      reloaded = Repo.get!(Product, product.id)
      assert reloaded.thumbnail == nil
    end

    test "returns :error when there are no candidate URLs at all" do
      product = insert_product!(%{image_url: nil})
      assert :error = ThumbnailServer.enqueue_sync(product.id)
    end

    test "deduplicates candidate URLs (product + listing share the same)" do
      product = insert_product!(%{image_url: "https://cdn.test/same.png"})
      l = insert_listing!(:unimarc, "sku-y", "https://cdn.test/same.png")
      link!(product.id, l.id)

      assert :ok = ThumbnailServer.enqueue_sync(product.id)
      assert MockTransport.gets() == ["https://cdn.test/same.png"]
    end
  end

  describe "enqueue/1 (async cast)" do
    test "drains via :sys.get_state and produces a thumbnail" do
      product = insert_product!(%{image_url: "https://cdn.test/q.png"})

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), Process.whereis(ThumbnailServer))

      ThumbnailServer.enqueue(product.id)
      # :sys.get_state is a synchronous round-trip → all preceding
      # casts have been processed by the time it returns.
      _state = :sys.get_state(ThumbnailServer)

      reloaded = Repo.get!(Product, product.id)
      assert %Image{variants: [_ | _]} = reloaded.thumbnail
    end

    test "metrics.total_handled increments after a cast" do
      product = insert_product!(%{image_url: "https://cdn.test/m.png"})
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), Process.whereis(ThumbnailServer))

      before = ThumbnailServer.metrics().total_handled
      ThumbnailServer.enqueue(product.id)
      _state = :sys.get_state(ThumbnailServer)
      after_count = ThumbnailServer.metrics().total_handled

      assert after_count == before + 1
    end
  end

  # Sanity: the library transport is wired to the in-memory mock
  # in the test env.
  test "library transport is the in-memory mock" do
    assert Application.get_env(:stupendous_thumbnails, :transport) ==
             StupendousThumbnails.Transport.Mock

    product = insert_product!(%{image_url: "https://cdn.test/check.png"})
    assert {:ok, _} = Thumbnails.ensure(product)
    assert MockTransport.gets() == ["https://cdn.test/check.png"]
  end
end

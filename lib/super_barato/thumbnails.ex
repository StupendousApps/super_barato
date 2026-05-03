defmodule SuperBarato.Thumbnails do
  @moduledoc """
  Super Barato glue around `StupendousThumbnails`. The library
  handles the R2 + libvips heavy lifting; this module owns the
  app-specific bits: which sizes to generate, how to derive the
  R2 key prefix from a product's image URL, and the fall-back
  rules for `thumbnail_url/1`.
  """

  require Logger

  alias SuperBarato.Catalog.Product
  alias SuperBarato.Repo
  alias StupendousThumbnails.Image

  @target_size 400
  @sizes [@target_size]
  @format :webp

  @doc """
  Public URL for the home cards. Prefers the largest available
  thumbnail variant; falls back to the raw chain CDN `image_url`
  when no thumbnail has been generated yet.
  """
  @spec thumbnail_url(Product.t()) :: String.t() | nil
  def thumbnail_url(%Product{thumbnail: %Image{} = image, image_url: fallback}) do
    Image.best_url(image, @target_size) || fallback
  end

  def thumbnail_url(%Product{image_url: url}), do: url

  @doc """
  Generate-and-upload a thumbnail for `product` if it doesn't
  have one yet and an `image_url` is available. Returns the
  updated product on success, the original on no-op or error.
  """
  @spec ensure(Product.t()) :: {:ok, Product.t()}
  def ensure(%Product{thumbnail: %Image{variants: [_ | _]}} = product), do: {:ok, product}
  def ensure(%Product{image_url: nil} = product), do: {:ok, product}
  def ensure(%Product{image_url: ""} = product), do: {:ok, product}

  def ensure(%Product{image_url: url} = product) do
    case StupendousThumbnails.fetch_and_generate(url, generate_opts(url)) do
      {:ok, image} ->
        update_product(product, url, image)

      {:error, reason} ->
        Logger.warning("thumbnails: skipping product #{product.id} — #{inspect(reason)}")
        {:ok, product}
    end
  end

  @doc """
  Override `product`'s thumbnail with one generated from
  `image_url`. Updates `product.image_url`, regenerates the
  variants, and (best-effort) deletes the previous R2 objects
  whose keys are no longer referenced by any other product.
  """
  @spec use_image(Product.t(), String.t()) ::
          {:ok, Product.t()} | {:error, term()}
  def use_image(%Product{} = product, image_url)
      when is_binary(image_url) and image_url != "" do
    old_image = product.thumbnail

    case StupendousThumbnails.fetch_and_generate(image_url, generate_opts(image_url)) do
      {:ok, new_image} ->
        case update_product(product, image_url, new_image) do
          {:ok, updated} ->
            if old_image, do: cleanup_old(old_image, updated.id)
            {:ok, updated}

          err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Walk the embed and delete every R2 object the product points
  at, but only those keys no surviving product still references.
  Used by `Catalog.delete_chain_category_listings/1` after
  hard-deleting orphan products.
  """
  @spec delete_unreferenced(Image.t(), pos_integer() | nil) :: :ok
  def delete_unreferenced(%Image{} = image, exclude_product_id \\ nil) do
    StupendousThumbnails.delete_unreferenced(image, fn key ->
      key_in_use_by_other?(key, exclude_product_id)
    end)
  end

  ## ── Internals ───────────────────────────────────────────────

  defp update_product(product, new_image_url, new_image) do
    attrs = %{image_url: new_image_url, thumbnail: Image.to_attrs(new_image)}

    product
    |> Product.changeset(attrs)
    |> Repo.update()
  end

  defp cleanup_old(%Image{} = image, surviving_product_id) do
    StupendousThumbnails.delete_unreferenced(image, fn key ->
      key_in_use_by_other?(key, surviving_product_id)
    end)
  end

  # SQLite + JSON1 lookup: any product (other than the surviving
  # one) whose `thumbnail` JSON has a variant with this key.
  defp key_in_use_by_other?(key, exclude_id) do
    import Ecto.Query

    base =
      from p in Product,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM json_each(json_extract(?, '$.variants')) WHERE json_extract(value, '$.key') = ?)",
            p.thumbnail,
            ^key
          )

    query =
      case exclude_id do
        nil -> base
        id -> from p in base, where: p.id != ^id
      end

    Repo.exists?(query)
  end

  defp generate_opts(image_url) do
    [
      sizes: @sizes,
      format: @format,
      key_prefix: key_prefix(image_url)
    ]
  end

  # Content-addressed prefix: same `image_url` → same R2 key
  # (the library appends `-<size>.<ext>`), so two products that
  # share an image dedup at the bucket level.
  defp key_prefix(url) do
    sha = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)
    "thumbnails/#{binary_part(sha, 0, 2)}/#{binary_part(sha, 2, 28)}"
  end
end

defmodule SuperBarato.Thumbnails do
  @moduledoc """
  Generate ~400px WebP thumbnails of product images and store them
  on Cloudflare R2.

  ## Flow

      Catalog upsert / backfill task
        │
        ▼
      Thumbnails.ensure(product)
        │  fetch image_url with Req
        │  resize to 400px max edge with libvips (vix)
        │  encode as WebP, q=80
        │  PUT to R2 via SigV4-signed Req call
        ▼
      product.thumbnail_key = "thumbnails/<sha>.webp"

  The R2 object key is content-addressed: SHA-256 of the source
  `image_url` is the basis, so the same URL is uploaded once and
  re-using the same thumbnail across products is free. Object keys
  are stored on the product so the home cards can render the public
  R2 URL without re-querying the bucket.

  Configuration lives under `config :super_barato, :r2` (see
  runtime.exs). When the config is missing every entry point becomes
  a no-op and `thumbnail_url/1` falls back to the raw chain CDN
  `image_url`. Useful for local dev where R2 credentials aren't set.
  """

  require Logger

  alias SuperBarato.Catalog.Product
  alias SuperBarato.Repo

  alias Vix.Vips.Image, as: VImage

  @max_edge 400
  @webp_quality 80

  @doc """
  Returns the URL the home cards should render for `product`.
  Prefers the R2-hosted thumbnail when the product carries a
  `thumbnail_key`; otherwise falls back to the raw `image_url`.
  """
  def thumbnail_url(%Product{thumbnail_key: key}) when is_binary(key) and key != "" do
    case public_base() do
      nil -> nil
      base -> base <> "/" <> key
    end
  end

  def thumbnail_url(%Product{image_url: url}), do: url

  @doc """
  Generate-and-upload a thumbnail for `product` if it doesn't have
  one yet and R2 is configured. Returns the updated product on
  success, the original product on no-op or error (errors logged).
  """
  def ensure(%Product{thumbnail_key: key} = product) when is_binary(key) and key != "",
    do: {:ok, product}

  def ensure(%Product{image_url: nil} = product), do: {:ok, product}
  def ensure(%Product{image_url: ""} = product), do: {:ok, product}

  def ensure(%Product{image_url: url} = product) do
    case config() do
      nil ->
        {:ok, product}

      r2 ->
        with {:ok, source} <- fetch(url),
             {:ok, webp} <- resize_webp(source),
             key = key_for(url),
             :ok <- upload(r2, key, webp) do
          product
          |> Product.changeset(%{thumbnail_key: key})
          |> Repo.update()
        else
          {:error, reason} ->
            Logger.warning("thumbnails: skipping product #{product.id} — #{inspect(reason)}")
            {:ok, product}
        end
    end
  end

  ## ── Internals ───────────────────────────────────────────────

  defp fetch(url) do
    case Req.get(url, decode_body: false, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, e} -> {:error, e}
    end
  end

  # Decode + resize in one pass. Vips' `thumbnail_buffer/2` reads,
  # downscales (keeping aspect ratio so the largest edge ≤ @max_edge),
  # and yields a Vix image; we then encode it to WebP.
  defp resize_webp(source_bin) do
    with {:ok, scaled} <- Vix.Vips.Operation.thumbnail_buffer(source_bin, @max_edge),
         {:ok, webp} <- VImage.write_to_buffer(scaled, ".webp[Q=#{@webp_quality}]") do
      {:ok, webp}
    end
  end

  defp key_for(url) do
    sha = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)
    "thumbnails/#{binary_part(sha, 0, 2)}/#{binary_part(sha, 2, 30)}.webp"
  end

  # PUT the object to R2. R2 speaks the S3 API on
  # https://<account>.r2.cloudflarestorage.com/<bucket>/<key> using
  # SigV4 signed against region "auto".
  defp upload(r2, key, body) do
    url = "https://#{r2[:account_id]}.r2.cloudflarestorage.com/#{r2[:bucket]}/#{key}"

    headers = sign_put(url, body, "image/webp", r2)

    case Req.put(url, body: body, headers: headers, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:r2_put, status, body}}
      {:error, e} -> {:error, e}
    end
  end

  defp sign_put(url, body, content_type, r2) do
    now = DateTime.utc_now()

    :aws_signature.sign_v4(
      r2[:access_key_id],
      r2[:secret_access_key],
      "auto",
      "s3",
      now |> DateTime.to_naive() |> NaiveDateTime.to_erl(),
      "PUT",
      url,
      [
        {"content-type", content_type},
        {"x-amz-content-sha256", :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)}
      ],
      body,
      []
    )
  end

  defp config do
    case Application.get_env(:super_barato, :r2) do
      nil ->
        nil

      r2 ->
        if Enum.all?([:account_id, :bucket, :access_key_id, :secret_access_key], &r2[&1]),
          do: r2,
          else: nil
    end
  end

  defp public_base do
    case config() do
      nil -> nil
      r2 -> r2[:public_base] && String.trim_trailing(r2[:public_base], "/")
    end
  end
end

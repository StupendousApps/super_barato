defmodule Mix.Tasks.Thumbnails.Backfill do
  @moduledoc """
  Walk every Product that has an `image_url` but no `thumbnail` embed,
  download the source image, resize/encode to ~400px WebP, and upload
  to R2 via `SuperBarato.Thumbnails`.

  Usage:

      mix thumbnails.backfill            # process all
      mix thumbnails.backfill --limit 50 # cap for a smoke test

  Runs serially so we don't hammer chain CDNs. R2 must be configured
  via the `R2_*` env vars; without it the task is a no-op.
  """
  use Mix.Task

  import Ecto.Query

  alias SuperBarato.Catalog.Product
  alias SuperBarato.Repo
  alias SuperBarato.Thumbnails

  @shortdoc "Generate R2 thumbnails for products that don't have one yet"

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [limit: :integer])
    limit = opts[:limit]

    query =
      from p in Product,
        where: not is_nil(p.image_url) and p.image_url != "" and is_nil(p.thumbnail),
        order_by: [desc: p.chain_count, asc: p.id]

    query = if limit, do: limit(query, ^limit), else: query

    products = Repo.all(query)
    total = length(products)
    IO.puts("thumbnails.backfill: #{total} products to process")

    {ok, fail} =
      products
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {p, i}, {ok, fail} ->
        case Thumbnails.ensure(p) do
          {:ok, %Product{thumbnail: %StupendousThumbnails.Image{variants: [v | _]}}} ->
            IO.puts("  [#{i}/#{total}] ✓ #{p.id} → #{v.key}")
            {ok + 1, fail}

          {:ok, _} ->
            {ok, fail + 1}

          other ->
            IO.puts("  [#{i}/#{total}] ✗ #{p.id} #{inspect(other)}")
            {ok, fail + 1}
        end
      end)

    IO.puts("done: ok=#{ok} skipped/failed=#{fail}")
  end
end

defmodule Mix.Tasks.Crawler.Products do
  @shortdoc "Runs stage 2 (product discovery) for a category slug via handle_task/1. No DB writes."

  @moduledoc """
  Exercises a chain's `handle_task/1` with a product-discovery task.
  Synchronous — bypasses the pipeline.

      mix crawler.products unimarc --category congelados
      mix crawler.products unimarc --category congelados/pescados-y-mariscos --limit 3
      mix crawler.products unimarc --category congelados --summary
  """

  use Mix.Task

  alias SuperBarato.Crawler

  @switches [category: :string, limit: :integer, summary: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadconfig")
    Logger.configure(level: :info)

    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    chain = parse_chain!(positional)
    slug = require_category!(opts)

    mod = Crawler.adapter(chain)
    task = {:discover_products, %{chain: chain, slug: slug}}

    case mod.handle_task(task) do
      {:ok, listings} ->
        shown =
          cond do
            opts[:summary] -> Enum.take(listings, 1)
            opts[:limit] -> Enum.take(listings, opts[:limit])
            true -> listings
          end

        Enum.each(shown, fn l ->
          IO.inspect(l, label: "listing", pretty: true, limit: :infinity)
        end)

        Mix.shell().info("  total: #{length(listings)}")

      :blocked ->
        Mix.shell().error("blocked — rotate/update curl-impersonate profile")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp parse_chain!([chain | _]), do: String.to_existing_atom(chain)

  defp parse_chain!([]) do
    Mix.shell().error(
      "Usage: mix crawler.products <chain> --category SLUG [--limit N] [--summary]"
    )

    exit({:shutdown, 1})
  end

  defp require_category!(opts) do
    case opts[:category] do
      slug when is_binary(slug) and slug != "" ->
        slug

      _ ->
        Mix.shell().error("--category SLUG is required")
        exit({:shutdown, 1})
    end
  end
end

defmodule Mix.Tasks.Crawler.Products do
  @shortdoc "Runs stage 2 (product discovery) for a category slug. No DB writes."

  @moduledoc """
  Exercises a chain's `discover_products/1` without touching the database.

      mix crawler.products unimarc --category congelados
      mix crawler.products unimarc --category congelados/pescados-y-mariscos --limit 3
      mix crawler.products unimarc --category congelados --summary
  """

  use Mix.Task

  alias SuperBarato.Crawler
  alias SuperBarato.Crawler.Runtime

  @switches [category: :string, limit: :integer, summary: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadconfig")
    Logger.configure(level: :info)

    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    chain = parse_chain!(positional)
    slug = require_category!(opts)
    Runtime.ensure_started(chain)

    mod = Crawler.adapter(chain)

    case mod.discover_products(slug) do
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

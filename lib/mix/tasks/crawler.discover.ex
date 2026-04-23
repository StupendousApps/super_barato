defmodule Mix.Tasks.Crawler.Discover do
  @shortdoc "Runs a chain's discovery adapter and prints the returned Listing structs (no DB writes)"

  @moduledoc """
  Exercises a chain's `discover_category/1` without touching the database.
  Prints each `SuperBarato.Crawler.Listing` struct and a summary.

      mix crawler.discover unimarc                # all seed categories from config
      mix crawler.discover unimarc --category 123 # single category id
      mix crawler.discover unimarc --limit 5      # cap printed listings

  Use `--summary` to print only a count + the first listing, useful when
  pointing at a large category.
  """

  use Mix.Task

  alias SuperBarato.Crawler
  alias SuperBarato.Crawler.Runtime

  @switches [category: :keep, limit: :integer, summary: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadconfig")
    Logger.configure(level: :info)

    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    chain = parse_chain!(positional)
    Runtime.ensure_started(chain)

    mod = Crawler.adapter(chain)
    categories = categories_from(opts, mod)

    if categories == [] do
      Mix.shell().error(
        "No categories. Pass --category ID or configure seed_categories in config."
      )

      exit({:shutdown, 1})
    end

    Mix.shell().info("discover #{chain}: #{length(categories)} categories")

    for category <- categories do
      Mix.shell().info("\n--- category=#{inspect(category)} ---")

      case mod.discover_category(category) do
        {:ok, listings} ->
          print_listings(listings, opts)

        {:error, reason} ->
          Mix.shell().error("  failed: #{inspect(reason)}")
      end
    end
  end

  defp parse_chain!([chain_str | _]), do: String.to_existing_atom(chain_str)

  defp parse_chain!([]) do
    Mix.shell().error(
      "Usage: mix crawler.discover <chain> [--category ID] [--limit N] [--summary]"
    )

    exit({:shutdown, 1})
  end

  defp categories_from(opts, mod) do
    case Keyword.get_values(opts, :category) do
      [] -> mod.seed_categories()
      list -> list
    end
  end

  defp print_listings(listings, opts) do
    count = length(listings)

    shown =
      if opts[:summary], do: Enum.take(listings, 1), else: maybe_limit(listings, opts[:limit])

    Enum.each(shown, fn listing ->
      IO.inspect(listing,
        label: "listing",
        pretty: true,
        limit: :infinity,
        printable_limit: :infinity
      )
    end)

    Mix.shell().info("  total: #{count}")
  end

  defp maybe_limit(listings, nil), do: listings
  defp maybe_limit(listings, n) when is_integer(n), do: Enum.take(listings, n)
end

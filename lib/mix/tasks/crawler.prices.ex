defmodule Mix.Tasks.Crawler.Prices do
  @shortdoc "Runs a chain's price fetch for given SKUs and prints the returned Price structs (no DB writes)"

  @moduledoc """
  Exercises a chain's `fetch_prices/1` without touching the database.
  Prints each `SuperBarato.Crawler.Price` struct and a summary.

      mix crawler.prices unimarc 12345 67890
      mix crawler.prices unimarc --sku 12345 --sku 67890
  """

  use Mix.Task

  alias SuperBarato.Crawler
  alias SuperBarato.Crawler.Runtime

  @switches [sku: :keep]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadconfig")
    Logger.configure(level: :info)

    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    {chain, positional_skus} = parse_args!(positional)
    flag_skus = Keyword.get_values(opts, :sku)
    skus = positional_skus ++ flag_skus

    if skus == [] do
      Mix.shell().error("No SKUs. Pass them positionally or via --sku.")
      exit({:shutdown, 1})
    end

    Runtime.ensure_started(chain)
    mod = Crawler.adapter(chain)

    Mix.shell().info("prices #{chain}: fetching #{length(skus)} SKUs")

    case mod.fetch_prices(skus) do
      {:ok, prices} ->
        Enum.each(prices, fn price ->
          IO.inspect(price,
            label: "price",
            pretty: true,
            limit: :infinity,
            printable_limit: :infinity
          )
        end)

        missing = skus -- Enum.map(prices, & &1.chain_sku)

        Mix.shell().info("  returned: #{length(prices)} / requested: #{length(skus)}")

        if missing != [] do
          Mix.shell().info("  missing: #{inspect(missing)}")
        end

      {:error, reason} ->
        Mix.shell().error("failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp parse_args!([chain_str | skus]), do: {String.to_existing_atom(chain_str), skus}

  defp parse_args!([]) do
    Mix.shell().error("Usage: mix crawler.prices <chain> [SKU...] [--sku SKU...]")
    exit({:shutdown, 1})
  end
end

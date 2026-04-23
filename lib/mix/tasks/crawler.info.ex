defmodule Mix.Tasks.Crawler.Info do
  @shortdoc "Runs stage 3 (product info refresh) for a batch of identifiers. No DB writes."

  @moduledoc """
  Exercises a chain's `fetch_product_info/1` without touching the database.
  The identifier is whatever the chain keys on: EAN for Unimarc, chain_sku
  (VTEX itemId) for Jumbo.

      mix crawler.info unimarc 7809611721655
      mix crawler.info unimarc 7809611721655 7807975007170
      mix crawler.info jumbo 23 104393
  """

  use Mix.Task

  alias SuperBarato.Crawler
  alias SuperBarato.Crawler.Runtime

  @switches [id: :keep, ean: :keep]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadconfig")
    Logger.configure(level: :info)

    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    {chain, positional_ids} = parse_args!(positional)
    flag_ids = Keyword.get_values(opts, :id) ++ Keyword.get_values(opts, :ean)
    ids = positional_ids ++ flag_ids

    if ids == [] do
      Mix.shell().error("No identifiers given. Pass positionally, via --id, or --ean.")
      exit({:shutdown, 1})
    end

    Runtime.ensure_started(chain)
    mod = Crawler.adapter(chain)
    field = mod.refresh_identifier()

    Mix.shell().info("info #{chain}: fetching #{length(ids)} #{field}(s)")

    case mod.fetch_product_info(ids) do
      {:ok, listings} ->
        Enum.each(listings, fn l ->
          IO.inspect(l, label: "product", pretty: true, limit: :infinity)
        end)

        returned_ids = Enum.map(listings, &Map.get(&1, field))
        missing = ids -- returned_ids

        Mix.shell().info("  returned: #{length(listings)} / requested: #{length(ids)}")
        if missing != [], do: Mix.shell().info("  missing: #{inspect(missing)}")

      {:error, reason} ->
        Mix.shell().error("failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp parse_args!([chain | rest]), do: {String.to_existing_atom(chain), rest}

  defp parse_args!([]) do
    Mix.shell().error("Usage: mix crawler.info <chain> [ID...] [--id ID | --ean EAN]...")
    exit({:shutdown, 1})
  end
end

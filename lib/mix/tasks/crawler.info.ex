defmodule Mix.Tasks.Crawler.Info do
  @shortdoc "Runs stage 3 (product info refresh) for a batch of identifiers via handle_task/1. No DB writes."

  @moduledoc """
  Exercises a chain's `handle_task/1` with a product-info task.
  Identifier is whatever the chain keys on: EAN for Unimarc,
  chain_sku (VTEX itemId) for Jumbo / Santa Isabel.

      mix crawler.info unimarc 7809611721655
      mix crawler.info jumbo 23 104393
  """

  use Mix.Task

  alias SuperBarato.Crawler

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

    mod = Crawler.adapter(chain)
    field = mod.refresh_identifier()
    task = {:fetch_product_info, %{chain: chain, identifiers: ids}}

    Mix.shell().info("info #{chain}: fetching #{length(ids)} #{field}(s)")

    case mod.handle_task(task) do
      {:ok, listings} ->
        Enum.each(listings, fn l ->
          IO.inspect(l, label: "product", pretty: true, limit: :infinity)
        end)

        returned_ids = Enum.map(listings, &Map.get(&1, field))
        missing = ids -- returned_ids

        Mix.shell().info("  returned: #{length(listings)} / requested: #{length(ids)}")
        if missing != [], do: Mix.shell().info("  missing: #{inspect(missing)}")

      :blocked ->
        Mix.shell().error("blocked — rotate/update curl-impersonate profile")
        exit({:shutdown, 1})

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

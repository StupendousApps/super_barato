defmodule Mix.Tasks.Crawler.Info do
  @shortdoc "Runs stage 3 (product info refresh) for a batch of EANs. No DB writes."

  @moduledoc """
  Exercises a chain's `fetch_product_info/1` without touching the database.

      mix crawler.info unimarc 7809611721655
      mix crawler.info unimarc 7809611721655 7807975007170
      mix crawler.info unimarc --ean 7809611721655 --ean 7807975007170
  """

  use Mix.Task

  alias SuperBarato.Crawler
  alias SuperBarato.Crawler.Runtime

  @switches [ean: :keep]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadconfig")
    Logger.configure(level: :info)

    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    {chain, positional_eans} = parse_args!(positional)
    flag_eans = Keyword.get_values(opts, :ean)
    eans = positional_eans ++ flag_eans

    if eans == [] do
      Mix.shell().error("No EANs given. Pass positionally or via --ean.")
      exit({:shutdown, 1})
    end

    Runtime.ensure_started(chain)
    mod = Crawler.adapter(chain)

    Mix.shell().info("info #{chain}: fetching #{length(eans)} EANs")

    case mod.fetch_product_info(eans) do
      {:ok, listings} ->
        Enum.each(listings, fn l ->
          IO.inspect(l, label: "product", pretty: true, limit: :infinity)
        end)

        missing = eans -- Enum.map(listings, & &1.ean)

        Mix.shell().info("  returned: #{length(listings)} / requested: #{length(eans)}")
        if missing != [], do: Mix.shell().info("  missing: #{inspect(missing)}")

      {:error, reason} ->
        Mix.shell().error("failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp parse_args!([chain | rest]), do: {String.to_existing_atom(chain), rest}

  defp parse_args!([]) do
    Mix.shell().error("Usage: mix crawler.info <chain> [EAN...] [--ean EAN...]")
    exit({:shutdown, 1})
  end
end

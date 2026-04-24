defmodule Mix.Tasks.Crawler.Categories do
  @shortdoc "Runs stage 1 (category tree discovery) via the adapter's handle_task/1. No DB writes."

  @moduledoc """
  Exercises a chain's `handle_task/1` with the discovery task shape.
  Synchronous — bypasses the pipeline (Queue/Worker/Results) and calls
  the adapter directly.

      mix crawler.categories unimarc
      mix crawler.categories unimarc --summary
      mix crawler.categories unimarc --leaves-only
  """

  use Mix.Task

  alias SuperBarato.Crawler

  @switches [summary: :boolean, leaves_only: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadconfig")
    Logger.configure(level: :info)

    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    chain = parse_chain!(positional)

    mod = Crawler.adapter(chain)
    task = {:discover_categories, %{chain: chain, parent: nil}}

    case mod.handle_task(task) do
      {:ok, categories} ->
        cats =
          if opts[:leaves_only], do: Enum.filter(categories, & &1.is_leaf), else: categories

        if opts[:summary] do
          print_summary(categories)
        else
          Enum.each(cats, fn c ->
            IO.inspect(c, label: "category", pretty: true, limit: :infinity)
          end)
        end

        Mix.shell().info(
          "  total: #{length(categories)} (leaves: #{Enum.count(categories, & &1.is_leaf)})"
        )

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
    Mix.shell().error("Usage: mix crawler.categories <chain> [--summary] [--leaves-only]")
    exit({:shutdown, 1})
  end

  defp print_summary(cats) do
    by_level = Enum.group_by(cats, & &1.level)

    Enum.each(Enum.sort(Map.keys(by_level)), fn lvl ->
      n = length(by_level[lvl])
      leaves = Enum.count(by_level[lvl], & &1.is_leaf)
      Mix.shell().info("  level #{lvl}: #{n} total, #{leaves} leaves")
    end)
  end
end

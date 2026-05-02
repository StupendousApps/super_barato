defmodule Mix.Tasks.Categories.Prune do
  @moduledoc """
  Drop chain_listings whose every chain_category sits inside a
  disabled branch (self or any ancestor with `crawl_enabled = false`).

      # all chains
      mix categories.prune

      # specific chain
      mix categories.prune jumbo

  Listings with no category attachments are left alone — those
  rows pre-date category tracking and shouldn't be collateral
  damage of a UI pruning step.
  """
  use Mix.Task

  alias SuperBarato.Catalog

  @shortdoc "Prune chain_listings whose categories are all disabled"

  @chains ~w(jumbo santa_isabel unimarc lider tottus acuenta)

  def run(args) do
    Mix.Task.run("app.start")

    chains = if args == [], do: @chains, else: args

    Enum.each(chains, fn chain ->
      n = Catalog.prune_disabled_branch_listings(chain)
      IO.puts("#{chain}: deleted #{n} listings under disabled branches")
    end)
  end
end

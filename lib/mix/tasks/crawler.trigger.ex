defmodule Mix.Tasks.Crawler.Trigger do
  @shortdoc "Runs a crawler stage end-to-end, synchronously, with DB writes + PriceLog appends."

  @moduledoc """
  Same effect as one of the Cron schedule entries firing, but on
  demand: fetches from the chain, persists to the DB, and appends
  price observations to the log files.

  Unlike the `crawler.categories` / `crawler.products` / `crawler.info`
  tasks (which print structs and don't persist), this one writes.

      mix crawler.trigger unimarc discover
          → one-shot category tree walk, upserts categories

      mix crawler.trigger unimarc products
          → walks every active leaf category in the DB

      mix crawler.trigger unimarc products --limit 5
          → walks the first 5 leaf categories (short smoke run)

      mix crawler.trigger unimarc products --category congelados
          → walks just that one category

  Options:

    * `--limit N`    cap the number of leaf categories walked
                     (products mode; ignored for discover)
    * `--category S` walk exactly one category by slug, skipping
                     the leaf-categories table lookup
    * `--interval MS` override the per-request pacing gap (default
                      from the chain's `:interval_ms` config)
  """

  use Mix.Task

  require Logger

  alias SuperBarato.{Catalog, Crawler}
  alias SuperBarato.Crawler.Chain.Results

  @switches [limit: :integer, category: :string, interval: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    Logger.configure(level: :info)

    {opts, positional} = OptionParser.parse!(args, strict: @switches)

    case positional do
      [chain_str, what] ->
        chain = String.to_existing_atom(chain_str)
        do_trigger(chain, what, opts)

      _ ->
        usage()
        exit({:shutdown, 1})
    end
  end

  defp do_trigger(chain, "discover", _opts) do
    mod = Crawler.adapter(chain)
    task = {:discover_categories, %{chain: chain, parent: nil}}

    Logger.info("[#{chain}] trigger: discover categories")

    case mod.handle_task(task) do
      {:ok, categories} ->
        Results.persist_sync(chain, mod, task, categories)

        Logger.info(
          "[#{chain}] trigger: discover done (#{length(categories)} categories, " <>
            "#{Enum.count(categories, & &1.is_leaf)} leaves)"
        )

      :blocked ->
        Mix.shell().error("[#{chain}] blocked — rotate or update curl-impersonate profile")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("[#{chain}] discover failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp do_trigger(chain, "products", opts) do
    mod = Crawler.adapter(chain)
    interval = Keyword.get(opts, :interval, chain_interval_ms(chain))
    slugs = resolve_slugs(chain, opts)

    if slugs == [] do
      Mix.shell().error("[#{chain}] no leaf categories to walk — run `discover` first")
      exit({:shutdown, 1})
    end

    Logger.info(
      "[#{chain}] trigger: products for #{length(slugs)} categories (gap #{interval}ms)"
    )

    {ok, blocked, errors} =
      Enum.reduce(slugs, {0, 0, 0}, fn slug, {ok, blocked, errors} ->
        if ok + blocked + errors > 0, do: Process.sleep(interval)

        task = {:discover_products, %{chain: chain, slug: slug}}

        case mod.handle_task(task) do
          {:ok, listings} ->
            Results.persist_sync(chain, mod, task, listings)
            Logger.info("[#{chain}] #{slug}: #{length(listings)} listings")
            {ok + 1, blocked, errors}

          :blocked ->
            Logger.warning("[#{chain}] #{slug}: blocked — stopping run")
            {ok, blocked + 1, errors}

          {:error, reason} ->
            Logger.warning("[#{chain}] #{slug} failed: #{inspect(reason)}")
            {ok, blocked, errors + 1}
        end
      end)

    Logger.info(
      "[#{chain}] trigger: products done — ok=#{ok} blocked=#{blocked} errors=#{errors}"
    )
  end

  defp do_trigger(_chain, other, _opts) do
    Mix.shell().error("unknown action: #{other}")
    usage()
    exit({:shutdown, 1})
  end

  defp resolve_slugs(chain, opts) do
    case opts[:category] do
      nil ->
        limit = opts[:limit]

        chain
        |> Catalog.leaf_categories()
        |> Enum.map(& &1.slug)
        |> then(fn all -> if limit, do: Enum.take(all, limit), else: all end)

      slug ->
        [slug]
    end
  end

  defp chain_interval_ms(chain) do
    :super_barato
    |> Application.get_env(SuperBarato.Crawler, [])
    |> Keyword.get(:chains, [])
    |> Keyword.get(chain, [])
    |> Keyword.get(:interval_ms, 1_000)
  end

  defp usage do
    Mix.shell().error("""
    Usage: mix crawler.trigger <chain> <discover|products> [opts]

      discover              run one-shot category tree walk
      products              walk leaf categories from DB and upsert listings

    Options (products only):
      --category SLUG       walk a single category, skip DB lookup
      --limit N             cap number of leaf categories walked
      --interval MS         per-request pacing gap (default: chain's config)

    Examples:
      mix crawler.trigger unimarc discover
      mix crawler.trigger unimarc products --limit 5
      mix crawler.trigger jumbo products --category congelados --interval 1500
    """)
  end
end

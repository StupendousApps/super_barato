defmodule SuperBarato.Crawler.ChainEndpointsTest do
  @moduledoc """
  Structural cross-check: for every (chain × scheduled producer) pair
  in `config/config.exs`, the chain's `handle_task/1` must accept the
  task kind that producer pushes. Otherwise the cron entry runs every
  week and the worker silently rejects every task with
  `{:error, {:unsupported_task, _}}`.

  We don't run the actual handlers (they'd hit live HTTP); we just
  drop a probe message into `handle_task/1` with each task kind it's
  supposed to handle and assert the response is **not** the
  unsupported_task fall-through. Real failure modes (HTTP, parse) are
  covered by per-chain unit tests against captured fixtures.
  """

  use ExUnit.Case, async: true

  alias SuperBarato.Crawler.{Acuenta, Jumbo, Lider, SantaIsabel, Tottus, Unimarc}

  # Map each producer module to the task kind it pushes onto the queue.
  @producer_task %{
    SuperBarato.Crawler.Chain.CategoryProducer => :discover_categories,
    SuperBarato.Crawler.Chain.ProductProducer => :discover_products,
    SuperBarato.Crawler.Cencosud.ProductProducer => :fetch_product_pdp,
    SuperBarato.Crawler.Chain.ListingProducer => :fetch_product_pdp
  }

  # Adapter module per chain id.
  @chain_adapter %{
    tottus: Tottus,
    lider: Lider,
    jumbo: Jumbo,
    santa_isabel: SantaIsabel,
    unimarc: Unimarc,
    acuenta: Acuenta
  }

  # Probe payload sufficient to hit the right `handle_task/1` clause
  # without doing real work. Each clause head pattern-matches on the
  # task tuple's shape; the probe just satisfies the pattern.
  @probe_payload %{
    discover_categories: %{parent: nil},
    discover_products: %{slug: "probe-slug"},
    fetch_product_pdp: %{url: "https://example.invalid/p"},
    fetch_product_info: %{identifiers: []}
  }

  describe "every scheduled producer's task kind has a handler" do
    test "all (chain, producer) pairs in config map to a handle_task clause" do
      pairs =
        Application.get_env(:super_barato, SuperBarato.Crawler, [])
        |> Keyword.get(:chains, [])
        |> Enum.flat_map(fn {chain, opts} ->
          opts
          |> Keyword.get(:schedule, [])
          |> Enum.map(fn {_cadence, {producer, :run, _}} -> {chain, producer} end)
        end)
        |> Enum.uniq()

      # Sanity: every chain in the config must be covered by the test
      # adapter map. Stops a future chain addition from quietly
      # skipping coverage.
      configured_chains = pairs |> Enum.map(fn {c, _} -> c end) |> Enum.uniq() |> MapSet.new()
      assert MapSet.subset?(configured_chains, MapSet.new(Map.keys(@chain_adapter))),
             "Unknown chain in config: #{inspect(MapSet.difference(configured_chains, MapSet.new(Map.keys(@chain_adapter))))}"

      missing =
        for {chain, producer} <- pairs,
            kind = Map.fetch!(@producer_task, producer),
            adapter = Map.fetch!(@chain_adapter, chain),
            not handles?(adapter, kind, @probe_payload[kind]) do
          {chain, producer, kind}
        end

      assert missing == [],
             "Chain handle_task gaps:\n" <>
               Enum.map_join(missing, "\n", fn {c, p, k} ->
                 "  #{c}: scheduled #{inspect(p)} fires #{inspect(k)} but the adapter rejects it"
               end)
    end
  end

  describe "ad-hoc task kinds the worker may receive" do
    # `:fetch_product_info` is fired by the admin "refresh by SKU"
    # path, not by the cron. Chains whose `refresh_identifier/0` is
    # `:chain_sku` should support it (the admin tool builds the
    # identifier list from chain_listing rows).
    @adhoc_pairs [
      {:tottus, :fetch_product_info},
      {:lider, :fetch_product_info},
      {:unimarc, :fetch_product_info}
    ]

    for {chain, kind} <- @adhoc_pairs do
      test "#{chain} accepts #{inspect(kind)}" do
        adapter = Map.fetch!(@chain_adapter, unquote(chain))
        assert handles?(adapter, unquote(kind), @probe_payload[unquote(kind)])
      end
    end
  end

  # An adapter "handles" the kind iff `handle_task/1` matches *any*
  # clause other than the catch-all `unsupported_task` one.
  #
  # We invoke in a Task with a tight timeout: real handlers will go
  # off and try to hit the network, which we abort. The unsupported
  # fall-through, by contrast, returns instantly. So if the call
  # didn't complete inside a few ms, we know it matched a real clause.
  defp handles?(adapter, kind, payload) do
    task = Task.async(fn ->
      try do
        adapter.handle_task({kind, payload})
      rescue
        _ -> :raised
      catch
        _kind, _value -> :caught
      end
    end)

    case Task.yield(task, 50) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:error, {:unsupported_task, _}}} -> false
      {:ok, _} -> true
      # Timed out (real handler doing work) or killed mid-run — both mean
      # the clause exists.
      nil -> true
    end
  end
end

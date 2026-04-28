defmodule SuperBarato.Linker.WorkerTest do
  use SuperBarato.DataCase, async: false

  alias SuperBarato.{Catalog, Linker, Repo}
  alias SuperBarato.Catalog.{ChainListing, Product, ProductIdentifier}
  alias SuperBarato.Crawler.Listing
  alias SuperBarato.Linker.{ProductListing, Worker}

  setup do
    # The Worker is a globally-registered GenServer started by the
    # application. Tests share it across describe blocks; each cast
    # is sync'd via :sys.get_state/1 to wait for the cast to drain.
    pid = Process.whereis(Worker)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    {:ok, pid: pid}
  end

  defp wait_for_worker(pid) do
    # Force a sync: get_state queues behind any pending cast, so
    # this returns only after the cast we just sent has finished.
    :sys.get_state(pid)
    :ok
  end

  defp listing(opts) do
    %Listing{
      chain: opts[:chain] || :unimarc,
      chain_sku: opts[:chain_sku] || "sku-#{System.unique_integer([:positive])}",
      ean: opts[:ean],
      identifiers_key:
        opts[:identifiers_key] || "sku=#{opts[:chain_sku] || System.unique_integer([:positive])}",
      name: opts[:name] || "Test Product",
      brand: opts[:brand] || "Brand X",
      regular_price: Keyword.get(opts, :regular_price, 1990),
      promo_price: opts[:promo_price],
      promotions: %{},
      raw: %{}
    }
  end

  defp insert!(opts) do
    {:ok, _action, row} = Catalog.upsert_listing(listing(opts))
    row
  end

  defp product_for_listing(id) do
    Repo.one(
      from p in Product,
        join: pl in ProductListing,
        on: pl.product_id == p.id,
        where: pl.chain_listing_id == ^id
    )
  end

  defp identifiers_for_product(pid) do
    from(pi in ProductIdentifier,
      where: pi.product_id == ^pid,
      select: {pi.kind, pi.value}
    )
    |> Repo.all()
    |> Enum.sort()
  end

  describe "link_listing/1 — listing with EAN" do
    test "creates a Product anchored on ean_13", %{pid: pid} do
      row =
        insert!(
          chain: :lider,
          ean: "7800000000009",
          identifiers_key: "ean=7800000000009",
          chain_sku: "sku-w1"
        )

      Worker.link_listing(row.id)
      wait_for_worker(pid)

      product = product_for_listing(row.id)
      assert product
      ids = identifiers_for_product(product.id)
      assert {"ean_13", "7800000000009"} in ids
      assert {"lider_sku", "sku-w1"} in ids

      [link] = Repo.all(from pl in ProductListing, where: pl.chain_listing_id == ^row.id)
      assert link.source == Linker.source_ean_canonical()
    end

    test "two listings with the same EAN converge on one Product (cross-chain)", %{pid: pid} do
      a =
        insert!(
          chain: :lider,
          ean: "7800000000016",
          identifiers_key: "ean=7800000000016,sku=a",
          chain_sku: "a"
        )

      b =
        insert!(
          chain: :unimarc,
          ean: "7800000000016",
          identifiers_key: "ean=7800000000016,sku=b",
          chain_sku: "b"
        )

      Worker.link_listing(a.id)
      Worker.link_listing(b.id)
      wait_for_worker(pid)

      pa = product_for_listing(a.id)
      pb = product_for_listing(b.id)
      assert pa.id == pb.id

      ids = identifiers_for_product(pa.id)
      assert {"ean_13", "7800000000016"} in ids
      assert {"lider_sku", "a"} in ids
      assert {"unimarc_sku", "b"} in ids
    end
  end

  describe "link_listing/1 — listing without EAN" do
    test "anchors on chain-scoped sku, source single_chain", %{pid: pid} do
      row =
        insert!(
          chain: :tottus,
          ean: nil,
          identifiers_key: "sku=tottus-w-1",
          chain_sku: "tottus-w-1"
        )

      Worker.link_listing(row.id)
      wait_for_worker(pid)

      product = product_for_listing(row.id)
      assert product

      ids = identifiers_for_product(product.id)
      assert ids == [{"tottus_sku", "tottus-w-1"}]

      [link] = Repo.all(from pl in ProductListing, where: pl.chain_listing_id == ^row.id)
      assert link.source == Linker.source_single_chain()
    end
  end

  describe "link_listing/1 — promotion-style transitions (the merge case)" do
    test "single_chain placeholder folds into the canonical EAN Product when EAN later appears",
         %{pid: pid} do
      # Step A: insert without EAN — gets a single_chain Product.
      row =
        insert!(
          chain: :tottus,
          ean: nil,
          identifiers_key: "sku=tottus-merge",
          chain_sku: "tottus-merge"
        )

      Worker.link_listing(row.id)
      wait_for_worker(pid)

      single_p = product_for_listing(row.id)
      assert single_p

      # Step B: separate listing on Lider that DOES have the EAN —
      # creates the canonical Product.
      lider =
        insert!(
          chain: :lider,
          ean: "7900000000006",
          identifiers_key: "ean=7900000000006,sku=L",
          chain_sku: "L"
        )

      Worker.link_listing(lider.id)
      wait_for_worker(pid)

      ean_p = product_for_listing(lider.id)
      assert ean_p
      assert ean_p.id != single_p.id

      # Step C: Tottus listing observed again, this time WITH the EAN.
      # Catalog upsert preserves identifiers_key so it's a different
      # row — we simulate the case by upserting a fresh listing whose
      # identifiers_key now includes the ean.
      tottus_with_ean =
        insert!(
          chain: :tottus,
          ean: "7900000000006",
          identifiers_key: "ean=7900000000006,sku=tottus-merge2",
          chain_sku: "tottus-merge2"
        )

      Worker.link_listing(tottus_with_ean.id)
      wait_for_worker(pid)

      assert product_for_listing(tottus_with_ean.id).id == ean_p.id
      ids = identifiers_for_product(ean_p.id)
      assert {"ean_13", "7900000000006"} in ids
      assert {"lider_sku", "L"} in ids
    end
  end

  describe "link_listing/1 — defense-in-depth no-price skip" do
    test "an existing chain_listing with current_regular_price = nil is not linked",
         %{pid: pid} do
      # Bypass Catalog.upsert_listing to insert a no-price row
      # directly — the Catalog rule would normally refuse this, but
      # legacy rows may already exist on prod. Worker should not
      # anchor a Product on them.
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, row} =
        %ChainListing{}
        |> ChainListing.discovery_changeset(%{
          chain: "tottus",
          chain_sku: "tottus-noprice",
          identifiers_key: "sku=tottus-noprice",
          ean: nil,
          name: "No price",
          first_seen_at: now,
          last_discovered_at: now,
          current_regular_price: nil,
          active: true,
          has_price: false,
          category_paths: []
        })
        |> Repo.insert()

      Worker.link_listing(row.id)
      wait_for_worker(pid)

      refute product_for_listing(row.id)
      assert Repo.aggregate(from(pl in ProductListing, where: pl.chain_listing_id == ^row.id), :count) == 0
    end
  end
end

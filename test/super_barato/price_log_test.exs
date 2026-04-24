defmodule SuperBarato.PriceLogTest do
  use ExUnit.Case, async: false
  # async: false because we override the app-wide :price_log_dir to a
  # temp directory for isolation. Multiple async tests would stomp on
  # each other's config.

  alias SuperBarato.PriceLog

  setup do
    dir =
      Path.join(System.tmp_dir!(), "sb_pricelog_#{System.unique_integer([:positive])}")

    :ok = File.mkdir_p!(dir) |> case do :ok -> :ok; other -> other end
    original = Application.get_env(:super_barato, :price_log_dir)
    Application.put_env(:super_barato, :price_log_dir, dir)

    on_exit(fn ->
      if original do
        Application.put_env(:super_barato, :price_log_dir, original)
      else
        Application.delete_env(:super_barato, :price_log_dir)
      end

      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  describe "append/5" do
    test "writes a regular-only line and creates the chain subdirectory", %{dir: dir} do
      :ok = PriceLog.append(:unimarc, "91590", 1490, nil, now: 1_700_000_000)

      path = Path.join([dir, "unimarc", "91590.log"])
      assert File.exists?(path)
      assert File.read!(path) == "1700000000 1490\n"
    end

    test "writes a regular+promo line when promo is set" do
      :ok = PriceLog.append(:jumbo, "23", 16_990, 14_990, now: 1_700_000_010)

      lines = File.read!(PriceLog.path_for(:jumbo, "23")) |> String.split("\n", trim: true)
      assert lines == ["1700000010 16990 14990"]
    end

    test "multiple appends accumulate in chronological order" do
      :ok = PriceLog.append(:unimarc, "a", 100, nil, now: 1_700_000_000)
      :ok = PriceLog.append(:unimarc, "a", 100, 90, now: 1_700_000_060)
      :ok = PriceLog.append(:unimarc, "a", 100, nil, now: 1_700_000_120)

      content = File.read!(PriceLog.path_for(:unimarc, "a"))

      assert content ==
               "1700000000 100\n1700000060 100 90\n1700000120 100\n"
    end

    test "chains are siblings, not stomping each other" do
      :ok = PriceLog.append(:unimarc, "123", 1000, nil, now: 1)
      :ok = PriceLog.append(:jumbo, "123", 2000, nil, now: 2)

      assert File.read!(PriceLog.path_for(:unimarc, "123")) == "1 1000\n"
      assert File.read!(PriceLog.path_for(:jumbo, "123")) == "2 2000\n"
    end

    test "uses system_time by default when :now not passed" do
      before = System.system_time(:second)
      :ok = PriceLog.append(:unimarc, "abc", 500)
      aft = System.system_time(:second)

      [{t, 500, nil}] = PriceLog.read(:unimarc, "abc")
      assert t >= before and t <= aft
    end
  end

  describe "read/2" do
    test "returns [] for unknown (chain, sku)" do
      assert PriceLog.read(:jumbo, "does-not-exist") == []
    end

    test "parses regular-only and regular+promo lines" do
      :ok = PriceLog.append(:unimarc, "x", 1000, nil, now: 10)
      :ok = PriceLog.append(:unimarc, "x", 1000, 900, now: 20)
      :ok = PriceLog.append(:unimarc, "x", 1100, nil, now: 30)

      assert PriceLog.read(:unimarc, "x") == [
               {10, 1000, nil},
               {20, 1000, 900},
               {30, 1100, nil}
             ]
    end

    test "skips malformed lines silently", %{dir: dir} do
      path = Path.join([dir, "unimarc", "bad.log"])
      File.mkdir_p!(Path.dirname(path))

      File.write!(path, """
      1700000000 1000
      garbage line
      1700000060 1100 900
      """)

      assert PriceLog.read(:unimarc, "bad") == [
               {1_700_000_000, 1000, nil},
               {1_700_000_060, 1100, 900}
             ]
    end
  end

  describe "path_for/2" do
    test "composes <root>/<chain>/<sku>.log" do
      path = PriceLog.path_for(:santa_isabel, "3033")
      assert String.ends_with?(path, "/santa_isabel/3033.log")
    end
  end

  describe "root_dir/0" do
    test "reads from app config" do
      assert PriceLog.root_dir() == Application.get_env(:super_barato, :price_log_dir)
    end
  end
end

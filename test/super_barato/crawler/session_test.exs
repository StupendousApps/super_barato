defmodule SuperBarato.Crawler.SessionTest do
  use ExUnit.Case, async: false
  # async: false — Session uses a single named ETS table.

  alias SuperBarato.Crawler.Session

  setup do
    # Use distinct chain atoms per test to avoid ETS cross-talk.
    chain = String.to_atom("test_#{System.unique_integer([:positive])}")
    Session.put(chain, :profile, nil)
    {:ok, chain: chain}
  end

  describe "rotate_profile/2" do
    test "with no current profile returns the first candidate", %{chain: chain} do
      assert Session.rotate_profile(chain, [:chrome116, :chrome107, :chrome100]) == :chrome116
      assert Session.get(chain, :profile) == :chrome116
    end

    test "advances to the next candidate", %{chain: chain} do
      Session.put(chain, :profile, :chrome116)
      assert Session.rotate_profile(chain, [:chrome116, :chrome107, :chrome100]) == :chrome107
      assert Session.get(chain, :profile) == :chrome107
    end

    test "from the last candidate wraps to the first", %{chain: chain} do
      Session.put(chain, :profile, :chrome100)
      assert Session.rotate_profile(chain, [:chrome116, :chrome107, :chrome100]) == :chrome116
    end

    test "an unknown current profile resets to the first candidate", %{chain: chain} do
      Session.put(chain, :profile, :ff117)
      assert Session.rotate_profile(chain, [:chrome116, :chrome107]) == :chrome116
    end

    test "persists in ETS — subsequent get/2 returns the new value", %{chain: chain} do
      Session.rotate_profile(chain, [:chrome116, :chrome107])
      assert Session.get(chain, :profile) == :chrome116
      Session.rotate_profile(chain, [:chrome116, :chrome107])
      assert Session.get(chain, :profile) == :chrome107
    end

    test "rotation through full cycle returns to start", %{chain: chain} do
      cs = [:a, :b, :c]
      assert Session.rotate_profile(chain, cs) == :a
      assert Session.rotate_profile(chain, cs) == :b
      assert Session.rotate_profile(chain, cs) == :c
      assert Session.rotate_profile(chain, cs) == :a
    end
  end

  describe "put/get/3 for arbitrary keys" do
    test "round-trips values", %{chain: chain} do
      Session.put(chain, :build_id, "abc123")
      assert Session.get(chain, :build_id) == "abc123"
    end

    test "returns nil for unset keys", %{chain: chain} do
      assert Session.get(chain, :missing) == nil
    end

    test "keys are scoped by chain", %{chain: chain} do
      other = :"#{chain}_other"
      Session.put(chain, :k, "a")
      Session.put(other, :k, "b")
      assert Session.get(chain, :k) == "a"
      assert Session.get(other, :k) == "b"
    end
  end
end

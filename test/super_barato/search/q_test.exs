defmodule SuperBarato.Search.QTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Search.Q

  describe "parse/1" do
    test "plain text → :or with single token" do
      assert Q.parse("Milo") == {:or, ["Milo"]}
    end

    test "leading/trailing whitespace trimmed on plain text" do
      assert Q.parse("  Milo  ") == {:or, ["Milo"]}
    end

    test "&& splits into AND tokens" do
      assert Q.parse("Milo&&230 g") == {:and, ["Milo", "230 g"]}
      assert Q.parse("Milo && 230 g") == {:and, ["Milo", "230 g"]}
    end

    test "|| splits into OR tokens" do
      assert Q.parse("Milo||Nesquik") == {:or, ["Milo", "Nesquik"]}
      assert Q.parse("Milo  ||  Nesquik") == {:or, ["Milo", "Nesquik"]}
    end

    test "more than two tokens" do
      assert Q.parse("Milo&&Nestle&&230 g") == {:and, ["Milo", "Nestle", "230 g"]}
    end

    test "empty terms around operators are dropped" do
      assert Q.parse("Milo&&") == {:and, ["Milo"]}
      assert Q.parse("&&Milo") == {:and, ["Milo"]}
      assert Q.parse("&&  &&Milo&&  ") == {:and, ["Milo"]}
    end

    test "empty input returns :empty" do
      assert Q.parse("") == :empty
      assert Q.parse("   ") == :empty
      assert Q.parse("&&") == :empty
      assert Q.parse("||") == :empty
    end

    test "first operator wins; the other becomes literal" do
      # `&&` appears first → AND mode, `||` stays in the right token
      assert Q.parse("a&&b||c") == {:and, ["a", "b||c"]}
      # `||` appears first → OR mode, `&&` stays in the right token
      assert Q.parse("a||b&&c") == {:or, ["a", "b&&c"]}
    end
  end
end

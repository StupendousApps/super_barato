defmodule SuperBarato.Linker.IdentityTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Linker.Identity

  describe "encode/1" do
    test "nil and empty map -> nil" do
      assert Identity.encode(nil) == nil
      assert Identity.encode(%{}) == nil
    end

    test "single key" do
      assert Identity.encode(%{"sku" => "123"}) == "sku=123"
    end

    test "is order-independent" do
      a = Identity.encode(%{"sku" => "1", "ean" => "780", "upc" => "12"})
      b = Identity.encode(%{"upc" => "12", "ean" => "780", "sku" => "1"})
      assert a == b
      # alphabetical: ean, sku, upc
      assert a == "ean=780,sku=1,upc=12"
    end

    test "atom and string keys equivalent" do
      assert Identity.encode(%{sku: "1"}) == Identity.encode(%{"sku" => "1"})
    end

    test "drops empty / nil values" do
      assert Identity.encode(%{"sku" => "1", "ean" => nil, "upc" => ""}) == "sku=1"
    end

    test "raises on forbidden chars in key or value" do
      assert_raise ArgumentError, ~r/forbidden char/, fn ->
        Identity.encode(%{"sku" => "12,3"})
      end

      assert_raise ArgumentError, ~r/forbidden char/, fn ->
        Identity.encode(%{"a=b" => "1"})
      end
    end
  end

  describe "valid_gtin13?/1" do
    # All values pulled from prod_snapshot.db
    test "real Cencosud GTIN-13 validates" do
      # 7801620290160 — Bilz 1.5 L
      assert Identity.valid_gtin13?("7801620290160")
      # 7802900332402 — Soprole yoghurt 1+1 zucaritas
      assert Identity.valid_gtin13?("7802900332402")
      # 7801620005290 — Kem Zero 3 L
      assert Identity.valid_gtin13?("7801620005290")
    end

    test "wrong length is invalid" do
      refute Identity.valid_gtin13?("780162029016")
      refute Identity.valid_gtin13?("78016202901600")
      refute Identity.valid_gtin13?("")
    end

    test "wrong check digit is invalid" do
      refute Identity.valid_gtin13?("7801620290161")
    end
  end

  describe "canonicalize_gtin13/1 — the cross-chain canonicalizer" do
    test "13-digit valid GTIN-13 returns as-is" do
      assert Identity.canonicalize_gtin13("7801620290160") == "7801620290160"
    end

    test "13-digit invalid GTIN-13 returns nil" do
      # off by one
      assert Identity.canonicalize_gtin13("7801620290161") == nil
    end

    test "Lider's 14-digit usItemId reduces to canonical GTIN-13" do
      # The user's screenshot showed:
      #   Lider stored: 00780290033240 (14 digits)
      #   Other chains:  7802900332402 (canonical GTIN-13, ends in check-digit 2)
      assert Identity.canonicalize_gtin13("00780290033240") == "7802900332402"

      # Bilz 1.5 L — canonical 7801620290160 (check digit 0)
      assert Identity.canonicalize_gtin13("00780162029016") == "7801620290160"

      # Pepsi Zero — 7801620006860
      assert Identity.canonicalize_gtin13("00780162000686") == "7801620006860"
    end

    test "12-digit (Lider's stripped form, or trailing-zero-loss) gets check digit appended" do
      assert Identity.canonicalize_gtin13("780290033240") == "7802900332402"
      assert Identity.canonicalize_gtin13("780162029016") == "7801620290160"
    end

    test "GTIN-14 with non-zero leading char is not a recoverable GTIN-13" do
      # GTIN-14 indicators 1..9 mark packaging levels (case, pallet, etc.);
      # their inner GTIN-13 is encoded differently and we can't recover it
      # safely. Refuse rather than guess.
      assert Identity.canonicalize_gtin13("17801620290160") == nil
    end

    test "EAN-8 returns nil — separate identifier space, no canonical GTIN-13" do
      # Real EAN-8 (Coca-Cola small bottle, hypothetical): "95011017".
      # GS1 doesn't define a conversion of EAN-8 → EAN-13; they're
      # distinct id namespaces. The Linker matches gtin8 against gtin8
      # separately when it cares.
      assert Identity.canonicalize_gtin13("95011017") == nil
    end

    test "UPC-A → EAN-13 promotion (12 digits, valid as 0+v)" do
      # 742832866378 is a real UPC-A from prod. Promotes to
      # 0742832866378 with valid check digit.
      assert Identity.canonicalize_gtin13("742832866378") == "0742832866378"
    end

    test "non-digit chars are stripped" do
      assert Identity.canonicalize_gtin13("780-1620-2901-60") == "7801620290160"
      assert Identity.canonicalize_gtin13("EAN: 7801620290160") == "7801620290160"
    end

    test "integer input" do
      assert Identity.canonicalize_gtin13(7_801_620_290_160) == "7801620290160"
    end

    test "nil / empty / short / nonsense returns nil" do
      assert Identity.canonicalize_gtin13(nil) == nil
      assert Identity.canonicalize_gtin13("") == nil
      assert Identity.canonicalize_gtin13("123") == nil
      assert Identity.canonicalize_gtin13("not a number") == nil
    end

    test "11-digit base recovered (Lider-style: data digits with leading zeros + check stripped)" do
      # Sacapita Galletas Saladas Sal de Mar 120g — Lider stores
      # `00074283214699` (14 chars). Strip leading zeros → 11
      # digits `74283214699` → pad to 12 with one leading zero,
      # append check digit. Canonical GTIN-13 = `0742832146999`,
      # which Jumbo and Unimarc carry verbatim.
      assert Identity.canonicalize_gtin13("00074283214699") == "0742832146999"
    end

    test "10-digit base recovered (Lider-style with two leading zeros stripped + check stripped)" do
      # Monster Energy Original 473ml — Lider stores
      # `00007084700951` (14 chars). Strip → 10 digits `7084700951`
      # → pad to 12 with two leading zeros → append check → 13.
      assert Identity.canonicalize_gtin13("00007084700951") == "0070847009511"

      # Pringles BBQ 158g — same shape.
      assert Identity.canonicalize_gtin13("00003800018371") == "0038000183713"
    end

    test "cross-chain symmetry — same product on every chain → same canonical" do
      jumbo = Identity.canonicalize_gtin13("7802900332402")
      santa_isabel = Identity.canonicalize_gtin13("7802900332402")
      unimarc = Identity.canonicalize_gtin13("7802900332402")
      lider_us_item = Identity.canonicalize_gtin13("00780290033240")
      lider_upc = Identity.canonicalize_gtin13("780290033240")

      assert jumbo == santa_isabel
      assert jumbo == unimarc
      assert jumbo == lider_us_item
      assert jumbo == lider_upc
      assert jumbo == "7802900332402"
    end
  end

  describe "canonicalize_ean8/1 — EAN-8 verbatim namespace" do
    test "8-digit numeric input is returned as-is" do
      assert Identity.canonicalize_ean8("78600010") == "78600010"
      assert Identity.canonicalize_ean8("90446849") == "90446849"
    end

    test "in-store / restricted prefixes still pass — no check-digit gate" do
      # Cencosud's 24xxxxxx granel codes — chains assign their own
      # numbering inside the GS1 reserved range. Same value on Jumbo
      # and SI is the cross-chain match we want; we don't filter.
      assert Identity.canonicalize_ean8("24959490") == "24959490"
      assert Identity.canonicalize_ean8("24856751") == "24856751"
    end

    test "non-digit chars stripped" do
      assert Identity.canonicalize_ean8("786-00010") == "78600010"
      assert Identity.canonicalize_ean8("ean: 78600010") == "78600010"
    end

    test "integer input" do
      assert Identity.canonicalize_ean8(78_600_010) == "78600010"
    end

    test "7-digit input gets EAN-8 check digit appended" do
      # Lider stores `00000007801418` (14 chars) for the same
      # Mote-con-Huesillos product Unimarc carries as `78014183`.
      # `7801418` → check digit `3` (EAN-8 weights 3,1,3,1,3,1,3
      # over the 7 data digits, sum 67, 10-(67%10) = 3).
      assert Identity.canonicalize_ean8("7801418") == "78014183"
    end

    test "Lider-style leading-zero-padded EAN-8 strips back to canonical" do
      # 14-char Lider form for Mote con Huesillos.
      assert Identity.canonicalize_ean8("00000007801418") == "78014183"

      # Other Lider 7-digit-base examples we found in the catalog.
      assert Identity.canonicalize_ean8("00000007804111") == "78041110"
      assert Identity.canonicalize_ean8("00000007800750") == "78007505"
    end

    test "wrong length returns nil" do
      assert Identity.canonicalize_ean8("123456") == nil
      assert Identity.canonicalize_ean8("123456789") == nil
      assert Identity.canonicalize_ean8("7801620290160") == nil
    end

    test "nil / empty / nonsense returns nil" do
      assert Identity.canonicalize_ean8(nil) == nil
      assert Identity.canonicalize_ean8("") == nil
      assert Identity.canonicalize_ean8("not a number") == nil
    end
  end
end

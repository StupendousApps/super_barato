defmodule SuperBarato.Linker.Identity do
  @moduledoc """
  Canonical-string encoder for a chain_listing's `identifiers` map.

  The crawler stores every id-shaped key the chain volunteered into
  the `identifiers` map (chain SKU, EAN, UPC, GTINs, internal product
  ids, etc.) — verbatim, no normalization. To use that map as part of
  the row's unique identity, we need a deterministic single-string
  representation of it: same set of (key, value) pairs → same string,
  regardless of insertion order or atom-vs-string keys. That string
  goes in `chain_listings.identifiers_key` and the `(chain,
  identifiers_key)` unique index ensures any change to the
  identifiers — added key, removed key, value change — produces a new
  row instead of clobbering the old one.

  Encoding rules:
    * Keys and values are coerced to strings (so atom/string keys are
      equivalent).
    * Pairs with empty / nil values are dropped — a chain not
      volunteering a key is the same as not having that key.
    * Pairs are sorted alphabetically by key.
    * Joined as `<key>=<value>` with a `,` delimiter.
    * Empty map / nil → `nil` (SQLite "every NULL is distinct" keeps
      degenerate "no identifiers" rows from colliding with each
      other on a single empty-string sentinel).

  Defensive: if any key or value contains a literal `,` or `=` we'd
  silently alias to a different identity. Raise instead — this should
  never happen with real GTIN/UPC/SKU values, and failing loud is
  better than a silent collision.
  """

  @forbidden ["=", ","]

  @spec encode(map | nil) :: String.t() | nil
  def encode(nil), do: nil
  def encode(m) when m == %{}, do: nil

  def encode(m) when is_map(m) do
    m
    |> Enum.map(&pair_to_string/1)
    |> Enum.reject(fn {_, v} -> v == "" end)
    |> Enum.sort()
    |> case do
      [] -> nil
      pairs -> Enum.map_join(pairs, ",", fn {k, v} -> "#{k}=#{v}" end)
    end
  end

  defp pair_to_string({k, v}) do
    sk = stringify(k)
    sv = stringify(v)
    check!(sk, "key")
    check!(sv, "value")
    {sk, sv}
  end

  defp stringify(nil), do: ""
  defp stringify(s) when is_binary(s), do: s
  defp stringify(a) when is_atom(a), do: Atom.to_string(a)
  defp stringify(n) when is_integer(n), do: Integer.to_string(n)
  defp stringify(other), do: to_string(other)

  defp check!(s, label) do
    if Enum.any?(@forbidden, &String.contains?(s, &1)) do
      raise ArgumentError,
            "identifier #{label} contains forbidden char (= or ,): #{inspect(s)}"
    end
  end

  ## ---------------------------------------------------------------
  ## GTIN-13 canonicalization
  ##
  ## Takes any chain-supplied id-shaped value (the value of a
  ## `gtin*`, `ean`, `upc`, `usItemId` field) and returns the
  ## 13-character canonical GTIN-13 string with a valid check digit,
  ## or nil if the input doesn't fit any recognized shape.
  ##
  ## Rules (all non-digit chars stripped first):
  ##
  ##   * 13 digits → if check digit validates as-is, return.
  ##     Otherwise try interpreting as a (GTIN-13 minus check) that
  ##     was numerically padded back to 13 with a leading zero —
  ##     strip leading zeros, recompute check digit. Fall through
  ##     to nil if neither works.
  ##   * 14 digits → first try GTIN-14 stripping (drop leading char,
  ##     validate the 13). If that fails, treat as a (GTIN-13 minus
  ##     check) padded to 14 with leading zeros: strip leading zeros
  ##     to 12, recompute check. Lider's `usItemId` always lands here.
  ##   * 12 digits → ambiguous. Two real-world interpretations:
  ##       (a) UPC-A → EAN-13 promotion: prepend "0", validate.
  ##       (b) GTIN-13 minus check: append computed check.
  ##     Try (a) first; if it validates, use it. Otherwise (b).
  ##   * 11 digits → pad to 13 with leading zeros, validate. Covers
  ##     EAN-13 emitted as a JSON number with multiple leading zeros
  ##     stripped.
  ##   * EAN-8 (8 digits) and other shapes → nil. EAN-8 is a distinct
  ##     identifier space with its own check-digit algorithm; there's
  ##     no canonical conversion to GTIN-13. The Linker can match
  ##     gtin8 against gtin8 separately when it cares.
  ## ---------------------------------------------------------------

  @spec canonicalize_gtin13(String.t() | integer() | nil) :: String.t() | nil
  def canonicalize_gtin13(nil), do: nil
  def canonicalize_gtin13(""), do: nil
  def canonicalize_gtin13(n) when is_integer(n), do: canonicalize_gtin13(Integer.to_string(n))

  def canonicalize_gtin13(s) when is_binary(s) do
    digits = String.replace(s, ~r/\D/, "")

    case byte_size(digits) do
      0 -> nil
      13 -> from_13(digits)
      14 -> from_14(digits)
      12 -> from_12(digits)
      11 -> pad_and_validate(digits)
      _ -> nil
    end
  end

  defp from_13(d) do
    if valid_gtin13?(d) do
      d
    else
      # Falls back to "leading zero padded a (GTIN-13 minus check)
      # form numerically" — strip and append check.
      stripped = String.trim_leading(d, "0")

      if byte_size(stripped) == 12 do
        append_check(stripped)
      else
        nil
      end
    end
  end

  # GTIN-14 with leading "0" only — that's either the
  # consumer-unit indicator (real, inner validates) OR a
  # zero-padded (12-digit base) form (Lider style). Indicators 1-9
  # mark packaging levels (case of N, pallet, etc.) with their own
  # distinct GTIN-13s; refuse to recover those because we'd
  # silently conflate the case-of-N with the consumer unit.
  defp from_14(<<"0", inner::binary-size(13)>> = d) do
    if valid_gtin13?(inner) do
      inner
    else
      zero_padded_to_13(d)
    end
  end

  defp from_14(_), do: nil

  defp from_12(d) do
    upc_promoted = "0" <> d
    # Distinguish UPC-A (12 digits *with* check) from a check-stripped
    # GTIN-13 by trying the standards-blessed UPC-A → EAN-13 promotion
    # first. If the check digit on `0` + d matches, use that. Otherwise
    # `d` is a check-stripped GTIN-13 → append the computed check.
    if valid_gtin13?(upc_promoted) do
      upc_promoted
    else
      append_check(d)
    end
  end

  defp zero_padded_to_13(d) do
    stripped = String.trim_leading(d, "0")

    case byte_size(stripped) do
      12 -> append_check(stripped)
      13 -> if valid_gtin13?(stripped), do: stripped, else: nil
      _ -> nil
    end
  end

  defp append_check(digits) when byte_size(digits) == 12 do
    digits <> check_digit(digits)
  end

  defp pad_and_validate(digits) do
    padded = String.pad_leading(digits, 13, "0")
    if valid_gtin13?(padded), do: padded, else: nil
  end

  @doc "Validate an EAN-13 check digit. Public for tests."
  @spec valid_gtin13?(String.t()) :: boolean()
  def valid_gtin13?(<<base::binary-size(12), check::binary-size(1)>>) do
    check_digit(base) == check
  end

  def valid_gtin13?(_), do: false

  # EAN-13 check digit on the 12 leading data digits. Weights
  # alternate 1, 3 starting at position 1 (leftmost). Returns the
  # check digit as a single-char string.
  defp check_digit(<<base::binary-size(12)>>) do
    sum =
      base
      |> String.to_charlist()
      |> Enum.with_index(1)
      |> Enum.reduce(0, fn {ch, i}, acc ->
        d = ch - ?0
        weight = if rem(i, 2) == 0, do: 3, else: 1
        acc + d * weight
      end)

    digit = rem(10 - rem(sum, 10), 10)
    Integer.to_string(digit)
  end
end

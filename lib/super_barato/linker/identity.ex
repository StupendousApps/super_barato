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
end

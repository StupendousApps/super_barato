# Triage progress dashboard.
#
#   mix run priv/repo/seeds/progress.exs
#
# Per chain: count of [ ] / [x] / [-] / [N] / total / % done.

alias SuperBarato.Catalog.CategoryChecklist

dir = Path.expand("categories", __DIR__)
chains = ~w(jumbo santa_isabel lider tottus unimarc acuenta)

format = fn n -> String.pad_leading(Integer.to_string(n), 4) end

stats =
  Enum.map(chains, fn chain ->
    path = Path.join(dir, "#{chain}.txt")
    entries = if File.exists?(path), do: CategoryChecklist.parse_file(path), else: []
    by_status = Enum.frequencies_by(entries, & &1.status)
    {chain, by_status, length(entries)}
  end)

IO.puts(
  String.pad_trailing("chain", 14) <>
    "  total " <>
    "   [ ] " <>
    "   [x] " <>
    "   [-] " <>
    "   [N] " <>
    "  done"
)

IO.puts(String.duplicate("-", 60))

for {chain, by, total} <- stats do
  unchecked = Map.get(by, :unchecked, 0)
  mapped = Map.get(by, :mapped, 0)
  no_match = Map.get(by, :no_match, 0)
  no_mapping = Map.get(by, :no_mapping, 0)
  done = mapped + no_match + no_mapping
  pct = if total > 0, do: round(100 * done / total), else: 0

  IO.puts(
    String.pad_trailing(chain, 14) <>
      "  #{format.(total)} " <>
      "  #{format.(unchecked)} " <>
      "  #{format.(mapped)} " <>
      "  #{format.(no_match)} " <>
      "  #{format.(no_mapping)} " <>
      "  #{String.pad_leading("#{pct}%", 4)}"
  )
end

IO.puts(String.duplicate("-", 60))

totals =
  Enum.reduce(stats, %{u: 0, m: 0, nm: 0, nM: 0, t: 0}, fn {_, by, total}, acc ->
    %{
      u: acc.u + Map.get(by, :unchecked, 0),
      m: acc.m + Map.get(by, :mapped, 0),
      nm: acc.nm + Map.get(by, :no_match, 0),
      nM: acc.nM + Map.get(by, :no_mapping, 0),
      t: acc.t + total
    }
  end)

done = totals.m + totals.nm + totals.nM
pct = if totals.t > 0, do: round(100 * done / totals.t), else: 0

IO.puts(
  String.pad_trailing("ALL", 14) <>
    "  #{format.(totals.t)} " <>
    "  #{format.(totals.u)} " <>
    "  #{format.(totals.m)} " <>
    "  #{format.(totals.nm)} " <>
    "  #{format.(totals.nM)} " <>
    "  #{String.pad_leading("#{pct}%", 4)}"
)

# One-off audit: print every [x] mapping with its full ancestry path
# alongside the target (cat/sub), and flag rows where path context
# suggests a likely misclassification (e.g. path mentions "Congelados"
# but the target isn't a congelados/* subcategory).
#
#   mix run priv/repo/seeds/audit_mappings.exs

alias SuperBarato.Catalog.CategoryChecklist

dir = Path.expand("categories", __DIR__)
chains = ~w(jumbo santa_isabel lider tottus unimarc acuenta)

# Heuristics: if the path contains keyword X but the target's category
# slug is not in `expected`, flag the row.
context_rules = [
  {~r/congelado/i, ["congelados"]},
  {~r/refrigerado|fresco/i, ["lacteos-y-refrigerados", "quesos-y-fiambres", "carnes-y-pescados"]},
  {~r/conserva/i, ["despensa"]},
  {~r/cervez/i, ["licores"]},
  {~r/limpie?za|aseo|detergente|jabón|jabon/i, ["aseo-y-limpieza", "cuidado-personal"]},
  {~r/mascota|perro|gato/i, ["mascotas"]},
  {~r/bebé|bebe |bebés|panales|pañales/i, ["bebe", "cuidado-personal"]},
  {~r/yoghurt|yogur/i, ["lacteos-y-refrigerados"]},
  {~r/leche/i, ["lacteos-y-refrigerados", "bebidas"]},
  {~r/queso/i, ["quesos-y-fiambres"]},
  {~r/pan(adería|aderia)|pasteleri?ía|pastelería/i, ["panaderia-y-pasteleria", "comidas-preparadas"]}
]

flag_path = fn path, target_cat ->
  Enum.find_value(context_rules, fn {regex, allowed_cats} ->
    if Regex.match?(regex, path) and target_cat not in allowed_cats do
      "path matches /#{regex.source}/ but target is `#{target_cat}` (expected one of #{Enum.join(allowed_cats, ", ")})"
    end
  end)
end

flagged = []
total = 0

{flagged, total} =
  Enum.reduce(chains, {[], 0}, fn chain, {flagged, total} ->
    path = Path.join(dir, "#{chain}.txt")

    if File.exists?(path) do
      entries =
        path
        |> CategoryChecklist.parse_file()
        |> Enum.filter(&(&1.status == :mapped))

      Enum.reduce(entries, {flagged, total + length(entries)}, fn e, {f, t} ->
        case flag_path.(e.path, e.mapping.category) do
          nil -> {f, t}
          reason -> {[{chain, e, reason} | f], t}
        end
      end)
    else
      {flagged, total}
    end
  end)

IO.puts("Audited #{total} [x] mappings.")
IO.puts("Flagged #{length(flagged)} likely misclassifications:\n")

for {chain, e, reason} <- Enum.reverse(flagged) do
  IO.puts("  [#{chain}] #{e.path}")
  IO.puts("      slug:   #{e.slug}")
  IO.puts("      mapped: #{e.mapping.category}/#{e.mapping.subcategory}")
  IO.puts("      reason: #{reason}")
  IO.puts("")
end

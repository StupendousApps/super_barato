#!/usr/bin/env bash
# High-confidence bulk_tag sweeps across all chains. Pass --dry-run as
# the first arg to preview what each one would match. Each sweep is a
# single (pattern → target) on every chain that has a checklist.

set -euo pipefail
cd "$(dirname "$0")/../../.."

DRY=${1:-}

# Order matters: the more-specific pattern goes first so the broader
# one can't capture it. (e.g. "Desodorantes Ambientales" before
# "Desodorante", so ambientales lands in aromatizantes not personal.)
SWEEPS=(
  # — Pantry / household basics
  "Detergente|aseo-y-limpieza/detergentes-suavizantes"
  "Suavizante|aseo-y-limpieza/detergentes-suavizantes"
  "Insecticida|aseo-y-limpieza/insecticidas-desinfeccion"
  "Plaguicida|aseo-y-limpieza/insecticidas-desinfeccion"
  "Bolsas de basura|aseo-y-limpieza/bolsas-envoltorios"
  "Papel Higiénico|aseo-y-limpieza/papeles"
  "Servilleta|aseo-y-limpieza/papeles"
  "Toallas de Papel|aseo-y-limpieza/papeles"
  # — Personal care
  "Desodorantes Ambientales|aseo-y-limpieza/aromatizantes"
  "Aromatizante|aseo-y-limpieza/aromatizantes"
  "Shampoo|cuidado-personal/cuidado-capilar"
  "Acondicionador|cuidado-personal/cuidado-capilar"
  "Pasta de Dientes|cuidado-personal/higiene-bucal"
  "Cepillo de Dientes|cuidado-personal/higiene-bucal"
  "Enjuague Bucal|cuidado-personal/higiene-bucal"
  # — Bebé
  "Pañales|bebe/panales"
  "Toallas Húmedas|bebe/panales"
  # — Lácteos
  "Yoghurt|lacteos-y-refrigerados/yoghurt"
  "Yogur|lacteos-y-refrigerados/yoghurt"
  "Mantequilla|lacteos-y-refrigerados/mantequillas-margarinas"
  "Margarina|lacteos-y-refrigerados/mantequillas-margarinas"
  # — Quesos / Fiambres
  "Quesos|quesos-y-fiambres/quesos"
  "Fiambres|quesos-y-fiambres/fiambres-y-embutidos"
  # — Bebidas
  "Aguas|bebidas/aguas"
  "Bebidas Energéticas|bebidas/energeticas-isotonicas"
  "Bebidas Isotónicas|bebidas/energeticas-isotonicas"
  "Té Helado|bebidas/te-frio"
  # — Licores
  "Cervezas|licores/cervezas"
  "Cerveza|licores/cervezas"
  "Vino Tinto|licores/vinos"
  "Vino Blanco|licores/vinos"
  "Vinos|licores/vinos"
  "Espumantes|licores/espumantes"
  "Destilados|licores/destilados"
  "Pisco|licores/destilados"
  "Whisky|licores/destilados"
  "Ron|licores/destilados"
  "Vodka|licores/destilados"
  "Tequila|licores/destilados"
  # — Carnes
  "Pollo|carnes-y-pescados/pollo"
  "Pavo|carnes-y-pescados/pavo"
  "Vacuno|carnes-y-pescados/vacuno"
  "Cerdo|carnes-y-pescados/cerdo-y-cordero"
  "Cordero|carnes-y-pescados/cerdo-y-cordero"
  "Salchicha|carnes-y-pescados/salchichas-y-parrilleros"
  # — Mascotas
  "Perros|mascotas/perros"
  "Gatos|mascotas/gatos"
  # — Snacks / sweets
  "Chocolate|desayuno-y-dulces/chocolates-y-dulces"
  "Mermelada|desayuno-y-dulces/mermeladas-miel-manjar"
  "Manjar|desayuno-y-dulces/mermeladas-miel-manjar"
  "Miel|desayuno-y-dulces/mermeladas-miel-manjar"
)

CHAINS=(jumbo lider tottus unimarc acuenta)

for sweep in "${SWEEPS[@]}"; do
  IFS='|' read -r pattern target <<< "$sweep"
  for chain in "${CHAINS[@]}"; do
    file="priv/repo/seeds/categories/$chain.txt"
    [ -s "$file" ] || continue
    out=$(MIX_ENV=dev mix run priv/repo/seeds/bulk_tag.exs "$chain" \
              --path-contains "$pattern" --to "$target" $DRY 2>/dev/null)
    n=$(echo "$out" | grep -c '^  ' || true)
    if [ "$n" -gt 0 ]; then
      printf '  %-12s %3d  %s -> %s\n' "$chain" "$n" "$pattern" "$target"
    fi
  done
done

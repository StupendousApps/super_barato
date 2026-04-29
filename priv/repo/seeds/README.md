# Category triage tooling

The unified taxonomy lives in `categories.yaml`. Per-chain checklists
live in `categories/<chain>.txt`. Each line block is parsed and
serialized by `SuperBarato.Catalog.CategoryChecklist`
(`lib/super_barato/catalog/category_checklist.ex`).

## Status quo

- `dump_categories.sql` + `dump_categories.sh` regenerate the per-chain
  checklist from the DB. Skips categories with `count = 0`.
- `sample_listings.sql` returns 7 random listings for a `(chain, slug)`
  pair — used to inspect real products before deciding a mapping.
- `CategoryChecklist.parse/1` and `serialize/1` round-trip the file
  format.

## Detour pending before triage can finish

Two chains can't be triaged yet — their `chain_listings.category_paths`
data doesn't match `categories.slug`:

- **santa_isabel**: 0 of 8540 listings have category_paths populated.
  Crawler isn't writing them. Nothing to salvage — needs re-crawl.
- **jumbo**: paths are stored as human-readable breadcrumbs
  (`"Carnes y Pescados > Vacuno > Carnes de Uso Diario"`) instead of
  slug arrays. `jumbo_breadcrumb_map.sql` builds a name→slug map by
  walking ancestry; output saved as `jumbo_breadcrumb_map.tsv`.
  Recovery rate (8370 listings):
  - 75% (6242) exact-match a category path.
  - 14% (1202) match a prefix only (L1 or L2 — L3 leaf names like
    `Vacuno`, `Aceites de Oliva` weren't crawled into `categories`).
  - 11% (926) under `Hogar, Juguetería y Librería` — non-grocery,
    safe to drop.

Fix both crawlers to write `category_paths` as a JSON array of
slugs (matching the `categories.slug` column for that chain), then
re-run `dump_categories.sh` and these two chains will populate.

The other four (lider, tottus, unimarc, acuenta) work today —
5,936 entries combined.

## Tools to build (in this order)

All tools should live in this directory as `*.exs` scripts run via
`mix run priv/repo/seeds/<name>.exs <args>`. They share
`SuperBarato.Catalog.CategoryChecklist` for parsing/serializing and
should hand-parse `categories.yaml` (no yaml dep needed for the
shape we use).

### 1. `progress.exs` — dashboard

Per chain, count `[ ]` / `[-]` / `[N]` / `[x]` and total. One-line
output per chain, plus an aggregate. Quick "how far am I" check.

### 2. `validate.exs` — referential integrity

Walk every checklist file. For each `[x]: {category, subcategory}`,
confirm the pair exists in `categories.yaml`. Print mismatches with
file + entry slug. Should run as part of `mix test` or a precommit
hook eventually.

### 3. `suggest.exs` — name-similarity auto-mapper

For each `[ ]` entry, find the best-matching unified subcategory by
name similarity (Jaro distance against the chain category's leaf
name vs. the unified subcategory name). When confidence is very high
(exact match or above a threshold), rewrite `[ ]` →
`[x]: {category, subcategory}`. Otherwise leave alone. Idempotent:
running twice should be a no-op once everything obvious is tagged.

### 4. `bulk_tag.exs` — sweep by pattern

CLI: `mix run priv/repo/seeds/bulk_tag.exs <chain> --path-contains
"Yoghurt" --to lacteos-y-refrigerados/yoghurt`. Rewrites every
matching `[ ]` entry to the supplied `(category, subcategory)`. Used
for obvious patterns the auto-suggester missed.

### 5. `review.exs` — side-by-side viewer

CLI: `mix run priv/repo/seeds/review.exs <chain> <slug>`. Prints:

- the category's path + count
- 7 random sample listings (use `sample_listings.sql` or compose in
  Elixir)
- top-3 unified-subcategory candidates ranked by Jaro similarity

Use to break ties on borderline cells without context-switching
between SQL, the YAML, and the checklist file.

## Conventions

- `[N]` is "no 1:1 mapping is possible". Reserve it for umbrella
  *roots* whose products have no coherent home (acuenta promo
  umbrellas like `Canasta Ahorradora` or `Día de la madre`,
  `Marcas Propias` with mixed contents). Note: umbrella *children*
  often DO map cleanly — `Marcas Tottus / Huevos` is real eggs and
  should be `[x]`-mapped to `despensa/huevos`, even though the parent
  `Marcas Tottus` may itself be `[N]`. Always inspect leaves before
  blanket-marking an umbrella.
- `[-]` is "I tried, nothing in the unified taxonomy fits" — flag
  for taxonomy gaps. If you see a lot of these clustering, the
  taxonomy probably needs a new subcategory.
- Empty (`count = 0`) chain categories are filtered out by
  `dump_categories.sql` and never reach the checklist.

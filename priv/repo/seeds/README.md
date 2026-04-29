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

## Tools

All tools live in this directory as `*.exs` scripts run via
`mix run priv/repo/seeds/<name>.exs <args>`. They share
`SuperBarato.Catalog.CategoryChecklist` for parsing/serializing and
read the unified taxonomy straight from the `app_categories` /
`app_subcategories` tables.

The `.txt` checklists are the source of truth. Whenever a tool
mutates them, it also regenerates the `chains:` blocks in
`categories.yaml` (a double-entry view) via `sync_yaml.exs`.

### `progress.exs`

    mix run priv/repo/seeds/progress.exs

Per chain, counts `[ ]` / `[x]` / `[-]` / `[N]` plus an `ALL` row and
a `% done`. Quick "how far am I" check.

### `validate.exs`

    mix run priv/repo/seeds/validate.exs

For each `[x]: {category, subcategory}`, confirms the pair exists in
the DB. Exits 1 on the first mismatch (so it can hook into CI later).

### `suggest.exs`

    mix run priv/repo/seeds/suggest.exs              # writes
    mix run priv/repo/seeds/suggest.exs --dry-run    # preview
    mix run priv/repo/seeds/suggest.exs -t 0.95      # tighter

For each `[ ]` entry, picks the AppSubcategory with the highest Jaro
distance to the entry's leaf name. Above threshold → rewrite to
`[x]`. Idempotent — running twice is a no-op once everything obvious
is tagged. Default threshold `0.92`; tighten with `-t` / loosen on
the same flag.

### `bulk_tag.exs`

    mix run priv/repo/seeds/bulk_tag.exs <chain> \
      --path-contains "Yoghurt" \
      --to lacteos-y-refrigerados/yoghurt

Sweeps `[ ]` entries whose path matches `--path-contains` (case-
insensitive substring) and rewrites them all to `--to`'s
`<category-slug>/<subcategory-slug>`. Add `--dry-run` to preview.

### `sync_yaml.exs`

    mix run priv/repo/seeds/sync_yaml.exs

Walks every checklist file, regroups `[x]` entries by `(category,
subcategory)`, and rewrites the `chains:` blocks in
`categories.yaml`. Idempotent. Preserves the taxonomy structure and
the leading comment header. `suggest.exs` and `bulk_tag.exs` invoke
this automatically after writing; run by hand whenever you edit a
`.txt` directly.

### `review.exs`

    mix run priv/repo/seeds/review.exs <chain> <slug>

For one chain category prints:

- ancestry path + listing count,
- 7 random sample listings,
- top-5 unified-subcategory candidates (Jaro ranked),
- a paste-ready `[x]: {...}` snippet for the top match.

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

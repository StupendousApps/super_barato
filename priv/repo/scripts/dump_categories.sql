-- Dump categories for one chain. Bind :chain as the only parameter.
--
-- Categories with zero listings (count = 0) are skipped — they
-- contribute nothing to triage, so the checklist stays focused on
-- categories that actually hold products.
--
-- Output (three lines per category, blank line between):
--   <entry-id> [ ]
--   <count padded-left to 4>  <ancestry-path>
--   <slug>
--
-- The entry-id is the first 8 hex chars of md5(<chain>|<slug>),
-- stamped by dump_categories.sh after sqlite emits its rows.
--
-- Run with:
--   sqlite3 priv/data/super_barato_dev.db < tmp/dump_categories.sql
-- (looped from a shell — see tmp/dump_categories.sh)

WITH RECURSIVE
  -- Per-slug listing counts via the chain_listing_categories join
  -- table (FK-correct, no JSON expansion). Replaces the legacy
  -- json_each(category_paths) path so jumbo (whose column held
  -- breadcrumb names instead of slugs) still produces real counts
  -- here — its 7,444 salvaged join rows are the source of truth now.
  counts(slug, n) AS (
    SELECT cc.slug, COUNT(*)
    FROM chain_listing_categories clc
    JOIN chain_categories cc ON cc.id = clc.chain_category_id
    WHERE cc.chain = :chain
    GROUP BY cc.slug
  ),
  -- Walk parent_slug from each category up to the root, accumulating
  -- the name path. depth bounds recursion.
  ancestry(slug, name, parent_slug, path, depth) AS (
    SELECT slug, name, parent_slug, name, 0
      FROM chain_categories
      WHERE chain = :chain
    UNION ALL
    SELECT a.slug, a.name, p.parent_slug, p.name || ' / ' || a.path, a.depth + 1
      FROM ancestry a
      JOIN chain_categories p
        ON p.chain = :chain
       AND p.slug = a.parent_slug
      WHERE a.depth < 16
  ),
  -- Each category's full path is the row whose parent_slug is NULL
  -- (we walked all the way to the root).
  full_path(slug, path) AS (
    SELECT slug, path FROM ancestry WHERE parent_slug IS NULL
  )
SELECT
  '[ ]' || char(10)
    || substr('    ' || COALESCE(c.n, 0), -4) || '  ' || fp.path
    || char(10) || fp.slug
    || char(10)
FROM full_path fp
JOIN counts c ON c.slug = fp.slug
WHERE c.n > 0
ORDER BY c.n DESC, LOWER(fp.path);

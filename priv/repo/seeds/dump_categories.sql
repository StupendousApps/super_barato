-- Dump categories for one chain. Bind :chain as the only parameter.
--
-- Output (three lines per category, blank line between):
--   [ ]
--   <count padded-left to 4>  <ancestry-path>
--   <slug>
--
-- Run with:
--   sqlite3 priv/data/super_barato_dev.db < tmp/dump_categories.sql
-- (looped from a shell — see tmp/dump_categories.sh)

WITH RECURSIVE
  -- Per-slug listing counts in this chain. One pass over chain_listings
  -- expanding category_paths via json_each, grouped once.
  counts(slug, n) AS (
    SELECT p.value, COUNT(*)
    FROM chain_listings cl, json_each(cl.category_paths) AS p
    WHERE cl.chain = :chain
    GROUP BY p.value
  ),
  -- Walk parent_slug from each category up to the root, accumulating
  -- the name path. depth bounds recursion.
  ancestry(slug, name, parent_slug, path, depth) AS (
    SELECT slug, name, parent_slug, name, 0
      FROM categories
      WHERE chain = :chain
    UNION ALL
    SELECT a.slug, a.name, p.parent_slug, p.name || ' / ' || a.path, a.depth + 1
      FROM ancestry a
      JOIN categories p
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
LEFT JOIN counts c ON c.slug = fp.slug
ORDER BY LOWER(fp.path);

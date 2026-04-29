-- Build a map from jumbo's breadcrumb strings (what got stored in
-- chain_listings.category_paths) to the real slug from the
-- chain_categories table. Used to salvage existing jumbo data before the
-- chain_listings.category_paths → join-table migration.
--
-- Two-pass match:
--   1. Exact: full breadcrumb path matches a category's ancestry path.
--   2. Prefix fallback: if exact misses, walk the breadcrumb left-
--      to-right and take the slug of the deepest ancestor we can
--      match. (Better to land at the L2 than to land nowhere.)
--
-- Output is one row per distinct breadcrumb:
--   <breadcrumb-name>\t<resolved-slug-or-NULL>\t<match-kind>\t<listing-count>
--
-- match-kind is 'exact', 'prefix', or 'none'.
-- A NULL slug means even the L1 didn't match (e.g. non-grocery
-- categories that were never crawled into chain_categories).
--
-- Run with:
--   sqlite3 -separator $'\t' priv/data/super_barato_dev.db \
--     < priv/repo/seeds/jumbo_breadcrumb_map.sql

WITH RECURSIVE
  -- Walk parent_slug to build the full name path for every jumbo
  -- category, joined with " > " (matching the breadcrumb separator).
  ancestry(slug, parent_slug, path, depth) AS (
    SELECT slug, parent_slug, name, 0
      FROM chain_categories WHERE chain = 'jumbo'
    UNION ALL
    SELECT a.slug, p.parent_slug, p.name || ' > ' || a.path, a.depth + 1
      FROM ancestry a
      JOIN chain_categories p ON p.chain = 'jumbo' AND p.slug = a.parent_slug
      WHERE a.depth < 16
  ),
  full_path(slug, path) AS (
    SELECT slug, path FROM ancestry WHERE parent_slug IS NULL
  ),
  -- Every (slug, path-prefix-up-to-this-node) pair, including
  -- intermediate ancestors. Used for the prefix fallback — if the
  -- full breadcrumb doesn't match, take the deepest prefix that does.
  -- depth here is the number of " > " separators in `path`; bigger
  -- depth = more specific match.
  any_prefix(slug, path, depth) AS (
    SELECT slug, path,
           (LENGTH(path) - LENGTH(REPLACE(path, ' > ', '')))/3
      FROM ancestry
  ),
  breadcrumbs(name_path, listings) AS (
    SELECT p.value, COUNT(*)
    FROM chain_listings cl, json_each(cl.category_paths) AS p
    WHERE cl.chain = 'jumbo'
    GROUP BY p.value
  ),
  -- Best prefix match for each breadcrumb: the path with the
  -- largest depth such that breadcrumb starts with `path` followed
  -- by either end-of-string or " > ".
  best_prefix(name_path, slug, depth) AS (
    SELECT b.name_path, ap.slug, MAX(ap.depth)
      FROM breadcrumbs b
      JOIN any_prefix ap
        ON b.name_path = ap.path
        OR b.name_path LIKE ap.path || ' > %'
      GROUP BY b.name_path
  )
SELECT
  b.name_path,
  COALESCE(fp.slug, bp.slug) AS slug,
  CASE
    WHEN fp.slug IS NOT NULL THEN 'exact'
    WHEN bp.slug IS NOT NULL THEN 'prefix'
    ELSE 'none'
  END AS match_kind,
  b.listings
FROM breadcrumbs b
LEFT JOIN full_path fp ON fp.path = b.name_path
LEFT JOIN best_prefix bp ON bp.name_path = b.name_path
ORDER BY b.listings DESC, b.name_path;

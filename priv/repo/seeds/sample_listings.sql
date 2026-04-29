-- Sample seven random listings from one chain category. Bind :chain
-- and :slug as parameters.
--
-- A listing is included if its category_paths array contains :slug.
-- Output is one block per listing, blank line between:
--
--   <brand> — <name>
--   $<regular_price> (sku <chain_sku>)
--   <pdp_url>
--
-- Useful when triaging a checklist entry — read seven real products
-- to decide which unified subcategory the chain category belongs in.
--
-- Run with:
--   sqlite3 priv/data/super_barato_dev.db \
--     -cmd ".parameter set :chain 'tottus'" \
--     -cmd ".parameter set :slug  'CATG27179/Leches'" \
--     < priv/repo/seeds/sample_listings.sql

SELECT
  COALESCE(NULLIF(cl.brand, ''), '?') || ' — ' || cl.name
    || char(10)
    || '$' || COALESCE(cl.current_regular_price, 0) || '  (sku ' || cl.chain_sku || ')'
    || char(10)
    || COALESCE(cl.pdp_url, '')
    || char(10)
FROM chain_listings cl
WHERE cl.chain = :chain
  AND EXISTS (
    SELECT 1 FROM json_each(cl.category_paths) AS p
    WHERE p.value = :slug
  )
ORDER BY RANDOM()
LIMIT 7;

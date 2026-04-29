-- Sample seven random listings from one chain category. Bind :chain
-- and :slug as parameters.
--
-- A listing is included if it joins to the (chain, slug) row in
-- chain_listing_categories. Output is one block per listing, blank
-- line between:
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
JOIN chain_listing_categories clc ON clc.chain_listing_id = cl.id
JOIN chain_categories cc ON cc.id = clc.chain_category_id
WHERE cl.chain = :chain
  AND cc.chain = :chain
  AND cc.slug = :slug
ORDER BY RANDOM()
LIMIT 7;

-- Sample random listings from one chain category. Bind :chain and
-- :slug as parameters.
--
-- Sample size scales: max(7, 7% of the bucket). Small buckets get
-- full-ish coverage at the 7-floor; big buckets get a representative
-- read without drowning the operator. A 50-product leaf returns 7;
-- a 677-product umbrella returns ~47.
--
-- A listing is included if it joins to the (chain, slug) row in
-- chain_listing_categories. Output is one block per listing, blank
-- line between:
--
--   <brand> — <name>
--   $<regular_price> (sku <chain_sku>)
--   <pdp_url>
--
-- Run with:
--   sqlite3 priv/data/super_barato_dev.db \
--     -cmd ".parameter set :chain 'tottus'" \
--     -cmd ".parameter set :slug  'CATG27179/Leches'" \
--     < priv/repo/seeds/sample_listings.sql

WITH bucket AS (
  SELECT cl.id AS listing_id
  FROM chain_listings cl
  JOIN chain_listing_categories clc ON clc.chain_listing_id = cl.id
  JOIN chain_categories cc ON cc.id = clc.chain_category_id
  WHERE cl.chain = :chain
    AND cc.chain = :chain
    AND cc.slug = :slug
),
sample_size AS (
  SELECT MAX(7, (SELECT COUNT(*) FROM bucket) * 7 / 100) AS n
)
SELECT
  COALESCE(NULLIF(cl.brand, ''), '?') || ' — ' || cl.name
    || char(10)
    || '$' || COALESCE(cl.current_regular_price, 0) || '  (sku ' || cl.chain_sku || ')'
    || char(10)
    || COALESCE(cl.pdp_url, '')
    || char(10)
FROM chain_listings cl
WHERE cl.id IN (SELECT listing_id FROM bucket)
ORDER BY RANDOM()
LIMIT (SELECT n FROM sample_size);

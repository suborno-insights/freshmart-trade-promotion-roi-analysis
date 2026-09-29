/*
Step 3 — Business logic verification: confirms each promotion
mechanic's price/discount was calculated correctly, no product has
overlapping promotions, and the cannibalization/forward-buying
patterns simulated during data generation (Decision 2.13) are
actually recoverable from the data. See DECISION_LOG.md, Decision 3.4.
*/

USE TradePromotionDB;
GO

-- ============================================================
-- A) Mechanic formula check — recompute the expected price/discount
--    from raw promotion inputs and compare to what was stored.
-- Expected: mismatches = 0 for all four mechanics.
-- ============================================================
SELECT 'Percentage Discount' AS mechanic, COUNT(*) AS mismatches
FROM Fact_Sales s
JOIN Fact_Promotion p ON s.promotion_id = p.promotion_id AND p.promotion_type_id = 1
JOIN Dim_Product d ON s.product_id = d.product_id
WHERE ABS(s.actual_unit_price - ROUND(d.regular_unit_price * (1 - p.discount_percentage/100.0), 2)) > 0.01

UNION ALL
SELECT 'Flat Discount', COUNT(*)
FROM Fact_Sales s
JOIN Fact_Promotion p ON s.promotion_id = p.promotion_id AND p.promotion_type_id = 2
JOIN Dim_Product d ON s.product_id = d.product_id
WHERE ABS(s.actual_unit_price - ROUND(d.regular_unit_price - p.flat_discount_amount, 2)) > 0.01

UNION ALL
SELECT 'BOGO price', COUNT(*)
FROM Fact_Sales s
JOIN Fact_Promotion p ON s.promotion_id = p.promotion_id AND p.promotion_type_id = 3
WHERE s.actual_unit_price NOT IN (0)
  AND s.actual_unit_price <> (SELECT regular_unit_price FROM Dim_Product WHERE product_id = s.product_id)

UNION ALL
SELECT 'Bundle discount_amount', COUNT(*)
FROM Fact_Sales s
JOIN Fact_Promotion p ON s.promotion_id = p.promotion_id AND p.promotion_type_id = 4
WHERE s.quantity <> p.bundle_quantity
   OR ABS(s.discount_amount - (s.quantity * s.actual_unit_price - p.bundle_price)) > 0.01;

-- ============================================================
-- B) Overlap check — no product should have two promotions running
--    at the same time (Decision 2.11's national-level, single-track
--    schedule). Expected: no rows returned.
-- ============================================================
SELECT p1.product_id, p1.promotion_id AS promo1, p2.promotion_id AS promo2
FROM Fact_Promotion p1
JOIN Fact_Promotion p2
  ON p1.product_id = p2.product_id
 AND p1.promotion_id < p2.promotion_id
 AND p1.start_date <= p2.end_date
 AND p2.start_date <= p1.end_date;

-- ============================================================
-- C) Forward-buying signal — Product 1's own sales should dip in the
--    5 days right after its own promotion ends (Decision 2.13:
--    forward-buy suppression factor 0.65). Result: 20 vs 32 units/day.
-- ============================================================
SELECT
  CASE
    WHEN t.sale_date > fp.end_date AND t.sale_date <= DATEADD(DAY, 5, fp.end_date) THEN 'Post-promo (5-day window)'
    ELSE 'Normal period'
  END AS period,
  AVG(t.daily_qty) AS avg_daily_units
FROM (
  SELECT CAST(transaction_datetime AS DATE) AS sale_date, SUM(quantity) AS daily_qty
  FROM Fact_Sales WHERE product_id = 1
  GROUP BY CAST(transaction_datetime AS DATE)
) t
CROSS JOIN (SELECT DISTINCT end_date FROM Fact_Promotion WHERE product_id = 1) fp
GROUP BY CASE
    WHEN t.sale_date > fp.end_date AND t.sale_date <= DATEADD(DAY, 5, fp.end_date) THEN 'Post-promo (5-day window)'
    ELSE 'Normal period'
  END;

-- ============================================================
-- D) Cannibalization signal — other Rice-category products should
--    sell less while Product 1 (also Rice) is on promotion
--    (Decision 2.13: cannibalization factor 0.85).
--
-- NOTE: a naive promo-vs-non-promo comparison (not shown here) came
-- back nearly flat (127 vs 128), because ~55% of Product 1's
-- promotions cluster around seasonal windows, and the seasonal
-- demand multiplier (x1.4) roughly cancels out the cannibalization
-- suppression (x0.85) on those same days. Restricting to non-seasonal
-- days isolates the effect. GROUP BY must use only the date (not the
-- full transaction_datetime) or SUM(quantity) collapses to
-- per-transaction quantities instead of true daily totals — an
-- earlier version of this query had that bug.
-- Result after the fix: 124 (non-promo) vs 112 (promo) units/day,
-- an ~10% drop, consistent with the 0.85 factor.
-- ============================================================
SELECT
  CASE WHEN fp.promotion_id IS NOT NULL THEN 'Promo period (product 1)' ELSE 'Non-promo period' END AS period,
  AVG(t.daily_qty) AS avg_daily_units
FROM (
  SELECT CAST(s.transaction_datetime AS DATE) AS sale_date, SUM(s.quantity) AS daily_qty
  FROM Fact_Sales s
  JOIN Dim_Product dp ON s.product_id = dp.product_id
  WHERE dp.category = 'Rice' AND s.product_id <> 1
  GROUP BY CAST(s.transaction_datetime AS DATE)
) t
JOIN Dim_Calendar c ON c.[date] = t.sale_date
LEFT JOIN Fact_Promotion fp
  ON fp.product_id = 1 AND t.sale_date BETWEEN fp.start_date AND fp.end_date
WHERE c.is_season_event = 0   -- exclude seasonal days to isolate the cannibalization effect
GROUP BY CASE WHEN fp.promotion_id IS NOT NULL THEN 'Promo period (product 1)' ELSE 'Non-promo period' END;

/*
Step 3 — Data audit: row counts, duplicates, orphan records, and
value sanity checks. Run after import, before adding foreign keys
(01_schema_constraints.sql). See DECISION_LOG.md, Decision 3.1-3.3.
*/

USE TradePromotionDB;
GO

-- ============================================================
-- A) Row counts — confirm nothing was lost on import
-- Expected: Fact_Sales 800313 | Fact_Promotion 475 | Dim_Calendar 1096
--           Dim_Product 36 | Dim_Store 20 | Dim_Division 8 | Dim_PromotionType 4
-- ============================================================
SELECT 'Fact_Sales' AS table_name, COUNT(*) AS row_count FROM Fact_Sales
UNION ALL SELECT 'Fact_Promotion', COUNT(*) FROM Fact_Promotion
UNION ALL SELECT 'Dim_Calendar', COUNT(*) FROM Dim_Calendar
UNION ALL SELECT 'Dim_Product', COUNT(*) FROM Dim_Product
UNION ALL SELECT 'Dim_Store', COUNT(*) FROM Dim_Store
UNION ALL SELECT 'Dim_Division', COUNT(*) FROM Dim_Division
UNION ALL SELECT 'Dim_PromotionType', COUNT(*) FROM Dim_PromotionType;

-- ============================================================
-- B) Blank-value check — confirm CSV blanks loaded as NULL, not ''
-- Expected: named_cnt = flagged_days = 126
-- ============================================================
SELECT
  SUM(CASE WHEN season_event_name IS NULL THEN 1 ELSE 0 END) AS null_cnt,
  SUM(CASE WHEN season_event_name = '' THEN 1 ELSE 0 END)   AS empty_string_cnt,
  SUM(CASE WHEN season_event_name IS NOT NULL AND season_event_name <> '' THEN 1 ELSE 0 END) AS named_cnt,
  SUM(CAST(is_season_event AS INT)) AS flagged_days
FROM Dim_Calendar;

-- Fact_Promotion: each promotion type should populate only its own
-- type-specific column. Expected: 177 / 113 / 112 / 73 (sums to 475).
SELECT
  COUNT(discount_percentage)     AS pct_rows,
  COUNT(flat_discount_amount)    AS flat_rows,
  COUNT(free_units_per_purchase) AS bogo_rows,
  COUNT(bundle_price)            AS bundle_rows
FROM Fact_Promotion;

-- ============================================================
-- C) Duplicate check — total rows should equal distinct keys
-- ============================================================
SELECT 'Fact_Sales' AS tbl, COUNT(*) AS total, COUNT(DISTINCT sale_line_id) AS distinct_keys FROM Fact_Sales
UNION ALL SELECT 'Fact_Promotion', COUNT(*), COUNT(DISTINCT promotion_id) FROM Fact_Promotion
UNION ALL SELECT 'Dim_Calendar', COUNT(*), COUNT(DISTINCT [date]) FROM Dim_Calendar
UNION ALL SELECT 'Dim_Product', COUNT(*), COUNT(DISTINCT product_id) FROM Dim_Product
UNION ALL SELECT 'Dim_Store', COUNT(*), COUNT(DISTINCT store_id) FROM Dim_Store
UNION ALL SELECT 'Dim_Division', COUNT(*), COUNT(DISTINCT division_id) FROM Dim_Division
UNION ALL SELECT 'Dim_PromotionType', COUNT(*), COUNT(DISTINCT promotion_type_id) FROM Dim_PromotionType;

-- ============================================================
-- D) Orphan check — every value should exist in 0 rows (all should be 0)
-- ============================================================
SELECT 'Sales -> Product' AS check_name, COUNT(*) AS orphans FROM Fact_Sales s
  WHERE NOT EXISTS (SELECT 1 FROM Dim_Product p WHERE p.product_id = s.product_id)
UNION ALL SELECT 'Sales -> Store', COUNT(*) FROM Fact_Sales s
  WHERE NOT EXISTS (SELECT 1 FROM Dim_Store d WHERE d.store_id = s.store_id)
UNION ALL SELECT 'Sales -> Promotion', COUNT(*) FROM Fact_Sales s
  WHERE s.promotion_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM Fact_Promotion f WHERE f.promotion_id = s.promotion_id)
UNION ALL SELECT 'Sales -> Calendar', COUNT(*) FROM Fact_Sales s
  WHERE NOT EXISTS (SELECT 1 FROM Dim_Calendar c WHERE c.[date] = CAST(s.transaction_datetime AS DATE))
UNION ALL SELECT 'Promotion -> Product', COUNT(*) FROM Fact_Promotion f
  WHERE NOT EXISTS (SELECT 1 FROM Dim_Product p WHERE p.product_id = f.product_id)
UNION ALL SELECT 'Promotion -> Type', COUNT(*) FROM Fact_Promotion f
  WHERE NOT EXISTS (SELECT 1 FROM Dim_PromotionType t WHERE t.promotion_type_id = f.promotion_type_id)
UNION ALL SELECT 'Promotion start -> Calendar', COUNT(*) FROM Fact_Promotion f
  WHERE NOT EXISTS (SELECT 1 FROM Dim_Calendar c WHERE c.[date] = f.start_date)
UNION ALL SELECT 'Promotion end -> Calendar', COUNT(*) FROM Fact_Promotion f
  WHERE NOT EXISTS (SELECT 1 FROM Dim_Calendar c WHERE c.[date] = f.end_date)
UNION ALL SELECT 'Store -> Division', COUNT(*) FROM Dim_Store s
  WHERE NOT EXISTS (SELECT 1 FROM Dim_Division d WHERE d.division_id = s.division_id);

-- ============================================================
-- E) Value sanity checks — all counts below should be 0
-- ============================================================
SELECT
  SUM(CASE WHEN quantity <= 0 THEN 1 ELSE 0 END)          AS bad_quantity,
  SUM(CASE WHEN actual_unit_price < 0 THEN 1 ELSE 0 END)  AS negative_price,
  SUM(CASE WHEN discount_amount < 0 THEN 1 ELSE 0 END)    AS negative_discount,
  SUM(CASE WHEN transaction_datetime < '2023-10-01' OR transaction_datetime >= '2026-10-01' THEN 1 ELSE 0 END) AS date_out_of_range
FROM Fact_Sales;

SELECT
  SUM(CASE WHEN start_date > end_date THEN 1 ELSE 0 END) AS bad_date_range,
  SUM(CASE WHEN discount_percentage IS NOT NULL AND (discount_percentage <= 0 OR discount_percentage >= 100) THEN 1 ELSE 0 END) AS bad_discount_pct,
  SUM(CASE WHEN bundle_price IS NOT NULL AND bundle_price <= 0 THEN 1 ELSE 0 END) AS bad_bundle_price
FROM Fact_Promotion;

-- Dim_Product margins should fall inside the category ranges set in
-- Decision 2.7 (e.g., Rice/Oil ~8-12%, Snacks ~30-35%) — visual check.
SELECT product_id, product_name, category, regular_unit_price, unit_cost,
  ROUND((regular_unit_price - unit_cost) / regular_unit_price * 100, 1) AS margin_pct
FROM Dim_Product
ORDER BY category;

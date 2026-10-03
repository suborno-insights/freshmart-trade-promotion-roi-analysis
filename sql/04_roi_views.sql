/*
Step 4 — Net ROI calculation chain.
Builds Net ROI as a sequence of SQL views, each depending on the one(s)
before it. Run in this order (dependency order matters).
See DECISION_LOG.md, Decision 4.1-4.4 for full reasoning behind the
matched day-type baseline methodology, and for why Decision 2.11's
discount ranges were later revised (Decision 4.3) after this chain
first revealed every promotion as loss-making.
*/

USE TradePromotionDB;
GO

-- ============================================================
-- 1) Net revenue per sale line (raw tables stay untouched, per
--    Decision 2.4 — net_revenue is calculated here, not stored).
-- ============================================================
CREATE VIEW vw_SalesWithRevenue AS
SELECT
    s.sale_line_id,
    s.transaction_id,
    CAST(s.transaction_datetime AS DATE) AS sale_date,
    s.store_id,
    s.product_id,
    s.quantity,
    s.actual_unit_price,
    s.discount_amount,
    s.promotion_id,
    (s.quantity * s.actual_unit_price) - s.discount_amount AS net_revenue
FROM Fact_Sales s;
GO

-- ============================================================
-- 2) Classify every calendar date into one of 4 types, combining
--    BD weekend (Fri-Sat) and seasonal-event flags. This is the
--    basis of the "matched day-type" baseline (Decision 4.1),
--    which Decision 3.4 showed is necessary — a naive promo vs.
--    non-promo average hides the cannibalization signal because
--    seasonal effects roughly cancel it out.
-- ============================================================
CREATE VIEW vw_CalendarDayType AS
SELECT
    [date],
    is_weekend,
    is_season_event,
    CASE
        WHEN is_weekend = 0 AND is_season_event = 0 THEN 'A'  -- normal day
        WHEN is_weekend = 1 AND is_season_event = 0 THEN 'B'  -- weekend only
        WHEN is_weekend = 0 AND is_season_event = 1 THEN 'C'  -- season only
        WHEN is_weekend = 1 AND is_season_event = 1 THEN 'D'  -- weekend + season
    END AS day_type
FROM Dim_Calendar;
GO

-- ============================================================
-- 3) Daily units/revenue per product, tagged with day_type and
--    which promotion (if any) was active that day. GROUP BY uses
--    only sale_date (not the full transaction_datetime) — an
--    earlier version of a related query mistakenly grouped by the
--    full timestamp too, which collapsed SUM(quantity) down to
--    per-transaction quantities instead of true daily totals
--    (see Decision 3.4's note on that bug).
-- ============================================================
CREATE VIEW vw_DailyProductSales AS
SELECT
    v.sale_date,
    v.product_id,
    ct.day_type,
    v.promotion_id,
    SUM(v.quantity) AS daily_units,
    SUM(v.net_revenue) AS daily_net_revenue
FROM vw_SalesWithRevenue v
JOIN vw_CalendarDayType ct ON ct.[date] = v.sale_date
GROUP BY v.sale_date, v.product_id, ct.day_type, v.promotion_id;
GO

-- ============================================================
-- 4) Baseline: average daily units per product, per day_type,
--    using non-promo days only. A promo day's expected ("what if
--    no promotion") sales are read from the matching day_type here,
--    not from an overall average.
-- ============================================================
CREATE VIEW vw_ProductBaseline AS
SELECT
    product_id,
    day_type,
    AVG(daily_units) AS baseline_avg_units
FROM vw_DailyProductSales
WHERE promotion_id IS NULL
GROUP BY product_id, day_type;
GO

-- ============================================================
-- 5) Component 1 — Incremental Units per promotion event: actual
--    units during the promotion minus the matched-day-type baseline,
--    summed across every day the promotion ran (so a 7-day promotion
--    spanning different day_types uses each day's own baseline,
--    not one flat average).
-- ============================================================
CREATE VIEW vw_IncrementalUnits AS
SELECT
    d.product_id,
    d.promotion_id,
    COUNT(*) AS promo_days,
    SUM(d.daily_units) AS actual_units,
    SUM(b.baseline_avg_units) AS baseline_units,
    SUM(d.daily_units) - SUM(b.baseline_avg_units) AS incremental_units
FROM vw_DailyProductSales d
JOIN vw_ProductBaseline b
    ON b.product_id = d.product_id AND b.day_type = d.day_type
WHERE d.promotion_id IS NOT NULL
GROUP BY d.product_id, d.promotion_id;
GO

-- ============================================================
-- 6) Average realized price per promotion event, derived from
--    net_revenue / quantity rather than AVG(actual_unit_price).
--    This was a bug fix (Decision 4.2): Bundle rows keep
--    actual_unit_price at the regular price with the real discount
--    isolated in discount_amount (Decision 2.12), so a plain average
--    of actual_unit_price ignored the Bundle discount entirely.
--    net_revenue already nets this out correctly for every mechanic.
-- ============================================================
CREATE VIEW vw_PromoAvgPrice AS
SELECT
    product_id,
    promotion_id,
    SUM(net_revenue) / SUM(quantity) AS avg_actual_price
FROM vw_SalesWithRevenue
WHERE promotion_id IS NOT NULL
GROUP BY product_id, promotion_id;
GO

-- ============================================================
-- 7) Component 2 — Incremental Profit: incremental units valued at
--    the realized margin (avg realized price minus unit cost). Can
--    be negative when the discounted price falls below cost.
-- ============================================================
CREATE VIEW vw_IncrementalProfit AS
SELECT
    iu.product_id,
    iu.promotion_id,
    iu.incremental_units,
    ap.avg_actual_price,
    dp.unit_cost,
    iu.incremental_units * (ap.avg_actual_price - dp.unit_cost) AS incremental_profit
FROM vw_IncrementalUnits iu
JOIN vw_PromoAvgPrice ap
    ON ap.product_id = iu.product_id AND ap.promotion_id = iu.promotion_id
JOIN Dim_Product dp
    ON dp.product_id = iu.product_id;
GO

-- ============================================================
-- 8) Component 3 — Cannibalization Loss: for every OTHER product in
--    the same category as the promoted product, sum the shortfall
--    (baseline - actual, floored at 0) on days the promoted product's
--    promotion was running, restricted to days the "other" product
--    itself had no promotion of its own (so its own promotion effect
--    isn't mistaken for cannibalization). Valued at that other
--    product's own regular margin.
-- ============================================================
CREATE VIEW vw_Cannibalization AS
SELECT
    promo.product_id AS promoted_product_id,
    promo.promotion_id,
    SUM(CASE WHEN b.baseline_avg_units > d.daily_units
             THEN b.baseline_avg_units - d.daily_units ELSE 0 END) AS cannibalized_units,
    SUM(CASE WHEN b.baseline_avg_units > d.daily_units
             THEN (b.baseline_avg_units - d.daily_units) * (dp2.regular_unit_price - dp2.unit_cost)
             ELSE 0 END) AS cannibalization_loss
FROM Fact_Promotion promo
JOIN Dim_Product dp1 ON dp1.product_id = promo.product_id
JOIN Dim_Product dp2 ON dp2.category = dp1.category AND dp2.product_id <> promo.product_id
JOIN vw_DailyProductSales d
    ON d.product_id = dp2.product_id
   AND d.sale_date BETWEEN promo.start_date AND promo.end_date
   AND d.promotion_id IS NULL
JOIN vw_ProductBaseline b
    ON b.product_id = d.product_id AND b.day_type = d.day_type
GROUP BY promo.product_id, promo.promotion_id;
GO

-- ============================================================
-- 9) Component 4 — Forward-Buy Loss: same shortfall logic as
--    Cannibalization, but applied to the promoted product's OWN
--    sales in the 5 days immediately after its promotion ends
--    (Decision 2.13's forward-buy window), excluding any days a
--    new promotion for the same product has already started.
--    Valued at the product's own regular margin (promotion is over).
-- ============================================================
CREATE VIEW vw_ForwardBuyLoss AS
SELECT
    promo.product_id,
    promo.promotion_id,
    SUM(CASE WHEN b.baseline_avg_units > d.daily_units
             THEN b.baseline_avg_units - d.daily_units ELSE 0 END) AS forward_buy_units,
    SUM(CASE WHEN b.baseline_avg_units > d.daily_units
             THEN (b.baseline_avg_units - d.daily_units) * (dp.regular_unit_price - dp.unit_cost)
             ELSE 0 END) AS forward_buy_loss
FROM Fact_Promotion promo
JOIN Dim_Product dp ON dp.product_id = promo.product_id
JOIN vw_DailyProductSales d
    ON d.product_id = promo.product_id
   AND d.sale_date > promo.end_date
   AND d.sale_date <= DATEADD(DAY, 5, promo.end_date)
   AND d.promotion_id IS NULL
JOIN vw_ProductBaseline b
    ON b.product_id = d.product_id AND b.day_type = d.day_type
GROUP BY promo.product_id, promo.promotion_id;
GO

-- ============================================================
-- 10) Component 5 — Promotion Cost, calculated differently per
--     mechanic (per Decision 2.10/2.12's raw-inputs design):
--       Percentage: (regular price x discount%) x units sold
--       Flat:       flat discount amount x units sold
--       BOGO:       unit_cost x free units given away (not revenue —
--                   the real cost is what it cost to make the item)
--       Bundle:     the discount_amount already recorded in Fact_Sales
-- ============================================================
CREATE VIEW vw_PromotionCost AS
SELECT
    fp.product_id,
    fp.promotion_id,
    fp.promotion_type_id,
    CASE fp.promotion_type_id
        WHEN 1 THEN
            (dp.regular_unit_price * fp.discount_percentage/100.0) *
            (SELECT SUM(quantity) FROM Fact_Sales WHERE promotion_id = fp.promotion_id)
        WHEN 2 THEN
            fp.flat_discount_amount *
            (SELECT SUM(quantity) FROM Fact_Sales WHERE promotion_id = fp.promotion_id)
        WHEN 3 THEN
            dp.unit_cost *
            (SELECT SUM(quantity) FROM Fact_Sales WHERE promotion_id = fp.promotion_id AND actual_unit_price = 0)
        WHEN 4 THEN
            (SELECT SUM(discount_amount) FROM Fact_Sales WHERE promotion_id = fp.promotion_id)
    END AS promotion_cost
FROM Fact_Promotion fp
JOIN Dim_Product dp ON dp.product_id = fp.product_id;
GO

-- ============================================================
-- 11) Component 6 — Net ROI: everything assembled.
--     LEFT JOINs (+ ISNULL) are used for cannibalization/forward-buy
--     because a promotion event can legitimately have zero loss on
--     either (e.g. no category-mate ever dipped below baseline) —
--     an INNER JOIN would have silently dropped that whole event.
-- ============================================================
CREATE VIEW vw_NetROI AS
SELECT
    ip.product_id,
    ip.promotion_id,
    dp.product_name,
    dp.category,
    pt.type_name AS promotion_type,
    ip.incremental_units,
    ip.incremental_profit,
    ISNULL(c.cannibalization_loss, 0) AS cannibalization_loss,
    ISNULL(fb.forward_buy_loss, 0) AS forward_buy_loss,
    pc.promotion_cost,
    (ip.incremental_profit - ISNULL(c.cannibalization_loss, 0)
                            - ISNULL(fb.forward_buy_loss, 0)
                            - pc.promotion_cost) AS net_profit,
    (ip.incremental_profit - ISNULL(c.cannibalization_loss, 0)
                            - ISNULL(fb.forward_buy_loss, 0)
                            - pc.promotion_cost) / pc.promotion_cost AS net_roi
FROM vw_IncrementalProfit ip
JOIN Dim_Product dp ON dp.product_id = ip.product_id
JOIN Fact_Promotion fp ON fp.promotion_id = ip.promotion_id
JOIN Dim_PromotionType pt ON pt.promotion_type_id = fp.promotion_type_id
JOIN vw_PromotionCost pc ON pc.promotion_id = ip.promotion_id
LEFT JOIN vw_Cannibalization c ON c.promotion_id = ip.promotion_id
LEFT JOIN vw_ForwardBuyLoss fb ON fb.product_id = ip.product_id AND fb.promotion_id = ip.promotion_id;
GO

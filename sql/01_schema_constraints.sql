/*
Step 3 — Schema cleanup and foreign key constraints.
Run only after all 7 CSVs have been imported via SSMS's
Import Flat File wizard (Decision 3.2) and the audit in
02_audit_queries.sql has returned clean results.
See DECISION_LOG.md, Decision 3.2 and 3.3 for full reasoning.
*/

USE TradePromotionDB;
GO

-- Dim_Store's CSV carries an extra division_name column, kept only
-- for readability at file-creation time (see DECISION_LOG.md, note
-- under Decision 2.5). Drop it so the table matches the finalized
-- 4-column design: store_id, store_name, city, division_id.
ALTER TABLE Dim_Store DROP COLUMN division_name;
GO

-- Foreign keys are added only after a clean audit (Decision 3.2/3.3),
-- so any orphan record would have already been caught, not silently
-- rejected here.

ALTER TABLE Dim_Store ADD CONSTRAINT FK_Store_Division
    FOREIGN KEY (division_id) REFERENCES Dim_Division(division_id);

ALTER TABLE Fact_Promotion ADD CONSTRAINT FK_Promo_Product
    FOREIGN KEY (product_id) REFERENCES Dim_Product(product_id);
ALTER TABLE Fact_Promotion ADD CONSTRAINT FK_Promo_Type
    FOREIGN KEY (promotion_type_id) REFERENCES Dim_PromotionType(promotion_type_id);
ALTER TABLE Fact_Promotion ADD CONSTRAINT FK_Promo_StartDate
    FOREIGN KEY (start_date) REFERENCES Dim_Calendar([date]);
ALTER TABLE Fact_Promotion ADD CONSTRAINT FK_Promo_EndDate
    FOREIGN KEY (end_date) REFERENCES Dim_Calendar([date]);

ALTER TABLE Fact_Sales ADD CONSTRAINT FK_Sales_Product
    FOREIGN KEY (product_id) REFERENCES Dim_Product(product_id);
ALTER TABLE Fact_Sales ADD CONSTRAINT FK_Sales_Store
    FOREIGN KEY (store_id) REFERENCES Dim_Store(store_id);
ALTER TABLE Fact_Sales ADD CONSTRAINT FK_Sales_Promotion
    FOREIGN KEY (promotion_id) REFERENCES Fact_Promotion(promotion_id);

-- No FK from Fact_Sales to Dim_Calendar: transaction_datetime is a
-- date-time value while Dim_Calendar's key is date-only, so a direct
-- constraint isn't possible. This relationship is verified instead in
-- 02_audit_queries.sql using CAST(transaction_datetime AS DATE), and
-- the same cast is used in analysis joins going forward.

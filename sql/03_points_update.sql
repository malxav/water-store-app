/* ============================================================
   WATER STORE DATABASE — Points Formula Update
   Run this AFTER water_store_schema.sql and water_store_procs.sql.
   Adds advance-payment points, without double-counting jugs
   bought using a Balance-funded transaction.
   ============================================================ */

USE WaterStoreDB;
GO

UPDATE dbo.AppConfig
SET ConfigValue = '125',
    Description = 'Pesos deposited as advance payment per point (125 = 5 jugs x 25 pesos, matching the Slim/Round rate)'
WHERE ConfigKey = 'PesosPerPointBalance';
GO

IF OBJECT_ID('dbo.vw_CustomerPoints', 'V') IS NOT NULL DROP VIEW dbo.vw_CustomerPoints;
GO

-- ------------------------------------------------------------
-- vw_CustomerPoints
--   Two point sources, added together:
--     1. PointsFromSlimRound — paid Slim/Round quantity / divisor.
--        Deliberately EXCLUDES Balance-funded transactions: that
--        money already earned points at deposit time (source #2),
--        so counting it again here would double-credit the same
--        pesos once as a deposit and once as a purchase.
--     2. PointsFromAdvancePayment — pesos deposited / PesosPerPointBalance.
--        This is what lets someone "catch up" on points before
--        fiscal year-end even before they've decided what to buy.
--   Both divisors are read from AppConfig, not hardcoded, so
--   updating the config table is enough if the ratio ever changes.
-- ------------------------------------------------------------
CREATE VIEW dbo.vw_CustomerPoints AS
WITH Config AS (
    SELECT
        CAST(MAX(CASE WHEN ConfigKey = 'PointsDivisorSlimRound' THEN ConfigValue END) AS DECIMAL(10,2)) AS SlimRoundDivisor,
        CAST(MAX(CASE WHEN ConfigKey = 'PesosPerPointBalance' THEN ConfigValue END) AS DECIMAL(10,2)) AS PesosPerPoint
    FROM dbo.AppConfig
),
FiscalYearLines AS (
    SELECT
        t.CustomerID,
        CASE WHEN MONTH(t.TransactionDate) >= 5
             THEN YEAR(t.TransactionDate) ELSE YEAR(t.TransactionDate) - 1 END AS FiscalYear,
        td.Quantity
    FROM dbo.SalesTransaction t
    JOIN dbo.TransactionDetail td ON td.TransactionID = t.TransactionID
    JOIN dbo.Item i ON i.ItemID = td.ItemID
    WHERE i.IsFreeVariant = 0
      AND i.ItemID IN (1, 2)          -- Slim, Round only
      AND t.FundingType <> 'Balance'  -- avoid double-counting deposit money
),
QtyPoints AS (
    SELECT
        f.CustomerID, f.FiscalYear,
        SUM(f.Quantity) AS SlimRoundQtyPurchased,
        FLOOR(SUM(f.Quantity) / cfg.SlimRoundDivisor) AS PointsFromSlimRound
    FROM FiscalYearLines f CROSS JOIN Config cfg
    GROUP BY f.CustomerID, f.FiscalYear, cfg.SlimRoundDivisor
),
FiscalYearDeposits AS (
    SELECT
        CustomerID,
        CASE WHEN MONTH(DepositDate) >= 5
             THEN YEAR(DepositDate) ELSE YEAR(DepositDate) - 1 END AS FiscalYear,
        Amount
    FROM dbo.AdvancePaymentDeposit
),
DepositPoints AS (
    SELECT
        d.CustomerID, d.FiscalYear,
        SUM(d.Amount) AS AmountDeposited,
        FLOOR(SUM(d.Amount) / cfg.PesosPerPoint) AS PointsFromAdvancePayment
    FROM FiscalYearDeposits d CROSS JOIN Config cfg
    GROUP BY d.CustomerID, d.FiscalYear, cfg.PesosPerPoint
)
SELECT
    COALESCE(q.CustomerID, d.CustomerID) AS CustomerID,
    COALESCE(q.FiscalYear, d.FiscalYear) AS FiscalYear,
    ISNULL(q.SlimRoundQtyPurchased, 0)     AS SlimRoundQtyPurchased,
    ISNULL(q.PointsFromSlimRound, 0)       AS PointsFromSlimRound,
    ISNULL(d.AmountDeposited, 0)           AS AmountDeposited,
    ISNULL(d.PointsFromAdvancePayment, 0)  AS PointsFromAdvancePayment,
    ISNULL(q.PointsFromSlimRound, 0) + ISNULL(d.PointsFromAdvancePayment, 0) AS TotalPoints
FROM QtyPoints q
FULL OUTER JOIN DepositPoints d
    ON d.CustomerID = q.CustomerID AND d.FiscalYear = q.FiscalYear;
GO

PRINT 'vw_CustomerPoints now includes advance-payment points.';

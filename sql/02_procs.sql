/* ============================================================
   WATER STORE DATABASE — Procedures & Operational Views
   Run water_store_schema.sql FIRST, then this script.
   Safe to re-run: everything is dropped before being recreated.
   ============================================================ */

USE WaterStoreDB;
GO

IF OBJECT_ID('dbo.usp_CreateTransaction', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_CreateTransaction;
IF OBJECT_ID('dbo.usp_AddAdvancePaymentDeposit', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_AddAdvancePaymentDeposit;
IF OBJECT_ID('dbo.usp_SettleDebt', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_SettleDebt;
IF OBJECT_ID('dbo.vw_CustomerPoints', 'V') IS NOT NULL DROP VIEW dbo.vw_CustomerPoints;
IF TYPE_ID('dbo.TransactionLineType') IS NOT NULL DROP TYPE dbo.TransactionLineType;
GO

-- ------------------------------------------------------------
-- Table type used to pass a whole order's line items into
-- usp_CreateTransaction in a single call (one row per item).
-- ------------------------------------------------------------
CREATE TYPE dbo.TransactionLineType AS TABLE (
    ItemID   INT NOT NULL,
    Quantity INT NOT NULL
);
GO

-- ------------------------------------------------------------
-- usp_CreateTransaction
--   Creates the transaction header + all line items in one call.
--   - Prices each line automatically from PriceList based on the
--     customer's segment (Regular/PDAO) — staff never has to
--     pick a price manually.
--   - Freebies are just ordinary lines using a free-variant
--     ItemID (e.g. "Slim (Free)"), which prices at 0 automatically.
--     Staff decides whether a freebie is earned; the system doesn't
--     auto-add one.
--   - If FundingType = 'Debt', a Debt row is created automatically.
--   - If FundingType = 'Balance', the call is blocked if the
--     customer's current balance can't cover the total.
-- ------------------------------------------------------------
CREATE PROCEDURE dbo.usp_CreateTransaction
    @CustomerID     INT = 0,
    @NameOnRecord   VARCHAR(100),
    @FundingType    VARCHAR(20),
    @ShippingFlag   BIT = 0,
    @Lines          dbo.TransactionLineType READONLY,
    @TransactionID  INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Segment VARCHAR(20);
        SELECT @Segment = CustomerSegment FROM dbo.Customer WHERE CustomerID = @CustomerID;
        IF @Segment IS NULL
            THROW 50000, 'Invalid CustomerID.', 1;

        IF NOT EXISTS (SELECT 1 FROM @Lines)
            THROW 50004, 'A transaction needs at least one line item.', 1;

        DECLARE @ShippingFee DECIMAL(10,2) = 0;
        IF @ShippingFlag = 1
            SELECT @ShippingFee = CAST(ConfigValue AS DECIMAL(10,2))
            FROM dbo.AppConfig WHERE ConfigKey = 'ShippingFee';

        INSERT INTO dbo.SalesTransaction (CustomerID, NameOnRecord, FundingType, ShippingFlag, ShippingFee, TotalAmount)
        VALUES (@CustomerID, @NameOnRecord, @FundingType, @ShippingFlag, @ShippingFee, 0);

        SET @TransactionID = SCOPE_IDENTITY();

        INSERT INTO dbo.TransactionDetail (TransactionID, ItemID, Quantity, UnitPriceSnapshot)
        SELECT
            @TransactionID,
            l.ItemID,
            l.Quantity,
            pl.UnitPrice
        FROM @Lines l
        CROSS APPLY (
            SELECT TOP 1 UnitPrice
            FROM dbo.PriceList
            WHERE ItemID = l.ItemID
              AND CustomerSegment = @Segment
              AND EffectiveDate <= CAST(GETDATE() AS DATE)
            ORDER BY EffectiveDate DESC
        ) pl;

        IF (SELECT COUNT(*) FROM @Lines) <> (SELECT COUNT(*) FROM dbo.TransactionDetail WHERE TransactionID = @TransactionID)
            THROW 50001, 'One or more items have no price defined for this customer''s segment.', 1;

        DECLARE @LinesTotal DECIMAL(10,2);
        SELECT @LinesTotal = SUM(LineTotal) FROM dbo.TransactionDetail WHERE TransactionID = @TransactionID;

        UPDATE dbo.SalesTransaction
        SET TotalAmount = ISNULL(@LinesTotal, 0) + @ShippingFee
        WHERE TransactionID = @TransactionID;

        IF @FundingType = 'Debt'
        BEGIN
            INSERT INTO dbo.Debt (TransactionID, AmountDue)
            SELECT TransactionID, TotalAmount FROM dbo.SalesTransaction WHERE TransactionID = @TransactionID;
        END

        IF @FundingType = 'Balance'
        BEGIN
            DECLARE @CurrentBalance DECIMAL(10,2), @FinalTotal DECIMAL(10,2);
            SELECT @CurrentBalance = CurrentBalance FROM dbo.vw_CustomerBalance WHERE CustomerID = @CustomerID;
            SELECT @FinalTotal = TotalAmount FROM dbo.SalesTransaction WHERE TransactionID = @TransactionID;

            IF ISNULL(@CurrentBalance, 0) < @FinalTotal
                THROW 50002, 'Customer does not have enough advance-payment balance for this transaction.', 1;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ------------------------------------------------------------
-- usp_AddAdvancePaymentDeposit
--   Logs a "loading money in" event. Calculates and stores the
--   expiry date at insert time (next AdvancePaymentExpiryMonth
--   following the deposit), per AppConfig.
--   NOTE: a deposit made *in* the expiry month itself currently
--   expires that same month (0 runway). Confirm with the org
--   whether that edge case should instead roll to next year —
--   flagged here rather than guessed.
-- ------------------------------------------------------------
CREATE PROCEDURE dbo.usp_AddAdvancePaymentDeposit
    @CustomerID    INT,
    @Amount        DECIMAL(10,2),
    @Channel       VARCHAR(20),
    @DepositDate   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @DepositDate IS NULL SET @DepositDate = CAST(GETDATE() AS DATE);

    DECLARE @ExpiryMonth INT = (SELECT CAST(ConfigValue AS INT) FROM dbo.AppConfig WHERE ConfigKey = 'AdvancePaymentExpiryMonth');
    DECLARE @ExpiryYear INT = CASE WHEN MONTH(@DepositDate) <= @ExpiryMonth THEN YEAR(@DepositDate) ELSE YEAR(@DepositDate) + 1 END;
    DECLARE @ExpiryDate DATE = EOMONTH(DATEFROMPARTS(@ExpiryYear, @ExpiryMonth, 1));

    INSERT INTO dbo.AdvancePaymentDeposit (CustomerID, DepositDate, Amount, Channel, ExpiryDate)
    VALUES (@CustomerID, @DepositDate, @Amount, @Channel, @ExpiryDate);

    SELECT SCOPE_IDENTITY() AS NewDepositID, @ExpiryDate AS ExpiryDate;
END
GO

-- ------------------------------------------------------------
-- usp_SettleDebt
--   Marks a debt Paid. Both known debt customers (Technocrete,
--   PDAO) pay in full, so this is a single-shot settlement,
--   not a partial-payment ledger.
-- ------------------------------------------------------------
CREATE PROCEDURE dbo.usp_SettleDebt
    @DebtID        INT,
    @Channel       VARCHAR(20),
    @DateSettled   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @DateSettled IS NULL SET @DateSettled = CAST(GETDATE() AS DATE);

    UPDATE dbo.Debt
    SET Status = 'Paid', DateSettled = @DateSettled, SettledChannel = @Channel
    WHERE DebtID = @DebtID AND Status = 'Unpaid';

    IF @@ROWCOUNT = 0
        THROW 50003, 'DebtID not found, or already settled.', 1;
END
GO

-- ------------------------------------------------------------
-- vw_CustomerPoints
--   Points earned per customer per fiscal year (fiscal year
--   starts in FiscalYearStartMonth = May, per AppConfig).
--   Only covers the Slim/Round term of the formula, since the
--   350ml/500ml divisor and the pesos-per-point-for-balance
--   ratio are still marked TBD in AppConfig. Extend this view
--   with those terms once the org finalizes them — don't
--   hardcode a guess here.
--   Free-variant lines are excluded (they're promo giveaways,
--   not purchases) — confirm this assumption with the org.
-- ------------------------------------------------------------
CREATE VIEW dbo.vw_CustomerPoints AS
WITH FiscalYearLines AS (
    SELECT
        t.CustomerID,
        CASE WHEN MONTH(t.TransactionDate) >= 5
             THEN YEAR(t.TransactionDate)
             ELSE YEAR(t.TransactionDate) - 1
        END AS FiscalYear,
        td.Quantity
    FROM dbo.SalesTransaction t
    JOIN dbo.TransactionDetail td ON td.TransactionID = t.TransactionID
    JOIN dbo.Item i ON i.ItemID = td.ItemID
    WHERE i.IsFreeVariant = 0
      AND i.ItemID IN (1, 2)   -- Slim, Round only
)
SELECT
    CustomerID,
    FiscalYear,
    SUM(Quantity) AS SlimRoundQtyPurchased,
    FLOOR(SUM(Quantity) / 5.0) AS PointsFromSlimRound
FROM FiscalYearLines
GROUP BY CustomerID, FiscalYear;
GO

PRINT 'Procedures and views created successfully.';
GO

/* ============================================================
   SAMPLE USAGE — uncomment to try it out after setup

-- Add a couple of real customers (PDAO example already seeded
-- as CustomerID 0 = walk-in; these get the next IDs, 1, 2...)
-- INSERT INTO dbo.Customer (CustomerName, AccountType, CustomerSegment)
-- VALUES ('PDAO', 'Organization', 'PDAO'), ('Malcolm', 'Individual', 'Regular');

-- A regular cash sale: 3 Slim + 2 Round, no freebie, no shipping
-- DECLARE @Lines1 dbo.TransactionLineType;
-- INSERT INTO @Lines1 (ItemID, Quantity) VALUES (1, 3), (2, 2);
-- DECLARE @NewTxnID1 INT;
-- EXEC dbo.usp_CreateTransaction
--     @CustomerID = 0, @NameOnRecord = 'Juan Dela Cruz',
--     @FundingType = 'Cash', @ShippingFlag = 0,
--     @Lines = @Lines1, @TransactionID = @NewTxnID1 OUTPUT;
-- SELECT * FROM dbo.SalesTransaction WHERE TransactionID = @NewTxnID1;
-- SELECT * FROM dbo.TransactionDetail WHERE TransactionID = @NewTxnID1;

-- Same order but hitting the 5-jug promo (3 Slim + 2 Round + 1 free Slim), shipped
-- DECLARE @Lines2 dbo.TransactionLineType;
-- INSERT INTO @Lines2 (ItemID, Quantity) VALUES (1, 3), (2, 2), (5, 1);
-- DECLARE @NewTxnID2 INT;
-- EXEC dbo.usp_CreateTransaction
--     @CustomerID = 0, @NameOnRecord = 'Juan Dela Cruz',
--     @FundingType = 'GCash', @ShippingFlag = 1,
--     @Lines = @Lines2, @TransactionID = @NewTxnID2 OUTPUT;
-- SELECT TotalAmount FROM dbo.SalesTransaction WHERE TransactionID = @NewTxnID2; -- expect 155.00

-- Load an advance payment for PDAO customer (assume CustomerID = 1)
-- EXEC dbo.usp_AddAdvancePaymentDeposit @CustomerID = 1, @Amount = 500, @Channel = 'GCash';
-- SELECT * FROM dbo.vw_CustomerBalance WHERE CustomerID = 1;

-- Check open debts and points
-- SELECT * FROM dbo.vw_OpenDebts;
-- SELECT * FROM dbo.vw_CustomerPoints;

   ============================================================ */

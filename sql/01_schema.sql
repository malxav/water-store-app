/* ============================================================
   WATER STORE DATABASE — Initial Setup Script
   Target: SQL Server (run in SSMS)

   Run this whole script top to bottom on a fresh database.
   It is safe to re-run: each object is dropped first if it
   already exists, so you can tweak and re-run while testing.
   ============================================================ */

-- ------------------------------------------------------------
-- 0. DATABASE
-- ------------------------------------------------------------
IF DB_ID('WaterStoreDB') IS NULL
BEGIN
    CREATE DATABASE WaterStoreDB;
END
GO

USE WaterStoreDB;
GO

-- ------------------------------------------------------------
-- Drop objects if they already exist (dependency-safe order)
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.vw_CustomerBalance', 'V') IS NOT NULL DROP VIEW dbo.vw_CustomerBalance;
IF OBJECT_ID('dbo.vw_OpenDebts', 'V') IS NOT NULL DROP VIEW dbo.vw_OpenDebts;
IF OBJECT_ID('dbo.AdvancePaymentDeposit', 'U') IS NOT NULL DROP TABLE dbo.AdvancePaymentDeposit;
IF OBJECT_ID('dbo.Debt', 'U') IS NOT NULL DROP TABLE dbo.Debt;
IF OBJECT_ID('dbo.TransactionDetail', 'U') IS NOT NULL DROP TABLE dbo.TransactionDetail;
IF OBJECT_ID('dbo.SalesTransaction', 'U') IS NOT NULL DROP TABLE dbo.SalesTransaction;
IF OBJECT_ID('dbo.PriceList', 'U') IS NOT NULL DROP TABLE dbo.PriceList;
IF OBJECT_ID('dbo.Item', 'U') IS NOT NULL DROP TABLE dbo.Item;
IF OBJECT_ID('dbo.Customer', 'U') IS NOT NULL DROP TABLE dbo.Customer;
IF OBJECT_ID('dbo.AppConfig', 'U') IS NOT NULL DROP TABLE dbo.AppConfig;
GO

-- ------------------------------------------------------------
-- 1. AppConfig — business rules that are known to change
--    (fiscal year start, expiry month, promo thresholds, etc.)
--    Update the ConfigValue here instead of editing code/queries.
-- ------------------------------------------------------------
CREATE TABLE dbo.AppConfig (
    ConfigKey       VARCHAR(50)     NOT NULL PRIMARY KEY,
    ConfigValue     VARCHAR(100)    NOT NULL,
    Description     VARCHAR(255)    NULL
);
GO

INSERT INTO dbo.AppConfig (ConfigKey, ConfigValue, Description) VALUES
('FiscalYearStartMonth',        '5',    'Fiscal year (points reset) begins in May'),
('AdvancePaymentExpiryMonth',   '9',    'Advance-payment balance expires on the next September following the deposit'),
('ShippingFee',                 '30',   'Flat shipping surcharge in pesos'),
('PromoThreshold1',             '5',    'Buy this many Slim/Round combined to unlock a freebie'),
('PromoFreebieQty1',            '1',    'Freebies granted at threshold 1'),
('PromoThreshold2',             '10',   'Buy this many Slim/Round combined to unlock the bigger freebie'),
('PromoFreebieQty2',            '2',    'Freebies granted at threshold 2'),
('PointsDivisorSlimRound',      '5',    'Every N Slim/Round jugs = 1 point'),
('PointsDivisorBottled',        'TBD',  'Divisor for 350ml/500ml points — not yet defined'),
('PesosPerPointBalance',        'TBD',  'How many pesos deposited as advance payment = 1 point — not yet defined');
GO

-- ------------------------------------------------------------
-- 2. Customer
--    CustomerID 0 is reserved for anonymous walk-ins.
--    "Name" is still captured per-transaction as a paper-trail
--    check even when a real CustomerID is used (see NameOnRecord
--    on SalesTransaction below).
-- ------------------------------------------------------------
CREATE TABLE dbo.Customer (
    CustomerID          INT IDENTITY(0,1)  NOT NULL PRIMARY KEY,
    CustomerName         VARCHAR(100)       NOT NULL,
    AccountType           VARCHAR(20)       NOT NULL DEFAULT 'Individual'
                                             CONSTRAINT CK_Customer_AccountType
                                             CHECK (AccountType IN ('Individual','Organization')),
    CustomerSegment       VARCHAR(20)       NOT NULL DEFAULT 'Regular'
                                             CONSTRAINT CK_Customer_Segment
                                             CHECK (CustomerSegment IN ('Regular','PDAO')),
    DateJoined            DATE              NOT NULL DEFAULT CAST(GETDATE() AS DATE)
);
GO

-- Claim CustomerID = 0 for anonymous walk-in transactions
SET IDENTITY_INSERT dbo.Customer ON;
INSERT INTO dbo.Customer (CustomerID, CustomerName, AccountType, CustomerSegment)
VALUES (0, 'Walk-in / Unregistered', 'Individual', 'Regular');
SET IDENTITY_INSERT dbo.Customer OFF;
GO

-- ------------------------------------------------------------
-- 3. Item
--    Free-variant items (e.g. "Slim (Free)") link back to their
--    paid counterpart via LinkedItemID so quantities can be
--    rolled up without matching on item name text.
-- ------------------------------------------------------------
CREATE TABLE dbo.Item (
    ItemID          INT IDENTITY(1,1)   NOT NULL PRIMARY KEY,
    ItemName        VARCHAR(50)         NOT NULL UNIQUE,
    IsFreeVariant   BIT                 NOT NULL DEFAULT 0,
    LinkedItemID    INT                 NULL
                        CONSTRAINT FK_Item_LinkedItem REFERENCES dbo.Item(ItemID)
);
GO

SET IDENTITY_INSERT dbo.Item ON;
INSERT INTO dbo.Item (ItemID, ItemName, IsFreeVariant, LinkedItemID) VALUES
(1, 'Slim',          0, NULL),
(2, 'Round',         0, NULL),
(3, '350ml',         0, NULL),
(4, '500ml',         0, NULL),
(5, 'Slim (Free)',   1, 1),
(6, 'Round (Free)',  1, 2);
SET IDENTITY_INSERT dbo.Item OFF;
GO

-- ------------------------------------------------------------
-- 4. PriceList
--    Price depends on ItemID + CustomerSegment, not on a
--    duplicated item. Free variants are priced 0 for every
--    segment.
-- ------------------------------------------------------------
CREATE TABLE dbo.PriceList (
    PriceID          INT IDENTITY(1,1)  NOT NULL PRIMARY KEY,
    ItemID           INT                NOT NULL
                          CONSTRAINT FK_PriceList_Item REFERENCES dbo.Item(ItemID),
    CustomerSegment  VARCHAR(20)        NOT NULL
                          CONSTRAINT CK_PriceList_Segment CHECK (CustomerSegment IN ('Regular','PDAO')),
    UnitPrice        DECIMAL(10,2)      NOT NULL,
    EffectiveDate    DATE               NOT NULL DEFAULT CAST(GETDATE() AS DATE),
    CONSTRAINT UQ_PriceList UNIQUE (ItemID, CustomerSegment, EffectiveDate)
);
GO

INSERT INTO dbo.PriceList (ItemID, CustomerSegment, UnitPrice) VALUES
(1, 'Regular', 25.00),   -- Slim
(2, 'Regular', 25.00),   -- Round
(3, 'Regular',  9.00),   -- 350ml
(4, 'Regular', 13.00),   -- 500ml
(1, 'PDAO',    30.00),   -- Slim (PDAO)
(2, 'PDAO',    30.00),   -- Round (PDAO)
(5, 'Regular',  0.00),   -- Slim (Free)
(5, 'PDAO',     0.00),
(6, 'Regular',  0.00),   -- Round (Free)
(6, 'PDAO',     0.00);
GO

-- ------------------------------------------------------------
-- 5. SalesTransaction (fact header)
-- ------------------------------------------------------------
CREATE TABLE dbo.SalesTransaction (
    TransactionID     INT IDENTITY(1,1)  NOT NULL PRIMARY KEY,
    CustomerID        INT                NOT NULL DEFAULT 0
                          CONSTRAINT FK_Transaction_Customer REFERENCES dbo.Customer(CustomerID),
    NameOnRecord      VARCHAR(100)       NOT NULL,
    TransactionDate   DATETIME           NOT NULL DEFAULT GETDATE(),
    FundingType       VARCHAR(20)        NOT NULL
                          CONSTRAINT CK_Transaction_FundingType CHECK (FundingType IN ('Cash','GCash','Debt','Balance')),
    ShippingFlag      BIT                NOT NULL DEFAULT 0,
    ShippingFee       DECIMAL(10,2)      NOT NULL DEFAULT 0,
    TotalAmount       DECIMAL(10,2)      NOT NULL DEFAULT 0
);
GO

CREATE INDEX IX_Transaction_Customer ON dbo.SalesTransaction(CustomerID);
CREATE INDEX IX_Transaction_Date ON dbo.SalesTransaction(TransactionDate);
GO

-- ------------------------------------------------------------
-- 6. TransactionDetail (fact line items)
--    UnitPriceSnapshot locks in the price at the moment of sale
--    so later price changes never rewrite history.
-- ------------------------------------------------------------
CREATE TABLE dbo.TransactionDetail (
    DetailID            INT IDENTITY(1,1)  NOT NULL PRIMARY KEY,
    TransactionID       INT                NOT NULL
                            CONSTRAINT FK_Detail_Transaction REFERENCES dbo.SalesTransaction(TransactionID),
    ItemID              INT                NOT NULL
                            CONSTRAINT FK_Detail_Item REFERENCES dbo.Item(ItemID),
    Quantity            INT                NOT NULL CONSTRAINT CK_Detail_Qty CHECK (Quantity > 0),
    UnitPriceSnapshot   DECIMAL(10,2)      NOT NULL,
    LineTotal           AS (Quantity * UnitPriceSnapshot) PERSISTED
);
GO

CREATE INDEX IX_Detail_Transaction ON dbo.TransactionDetail(TransactionID);
CREATE INDEX IX_Detail_Item ON dbo.TransactionDetail(ItemID);
GO

-- ------------------------------------------------------------
-- 7. Debt
--    One row per debt-funded transaction. Both known debt
--    customers (Technocrete, PDAO) pay in full, so no
--    installment ledger — just Unpaid/Paid.
-- ------------------------------------------------------------
CREATE TABLE dbo.Debt (
    DebtID           INT IDENTITY(1,1)  NOT NULL PRIMARY KEY,
    TransactionID    INT                NOT NULL UNIQUE
                          CONSTRAINT FK_Debt_Transaction REFERENCES dbo.SalesTransaction(TransactionID),
    AmountDue        DECIMAL(10,2)      NOT NULL,
    Status           VARCHAR(20)        NOT NULL DEFAULT 'Unpaid'
                          CONSTRAINT CK_Debt_Status CHECK (Status IN ('Unpaid','Paid')),
    DateIncurred     DATE               NOT NULL DEFAULT CAST(GETDATE() AS DATE),
    DateSettled      DATE               NULL,
    SettledChannel   VARCHAR(20)        NULL
                          CONSTRAINT CK_Debt_Channel CHECK (SettledChannel IN ('Cash','GCash') OR SettledChannel IS NULL)
);
GO

-- ------------------------------------------------------------
-- 8. AdvancePaymentDeposit
--    ExpiryDate is calculated and stored at the time of deposit
--    (next September following the deposit date), so later
--    changes to AppConfig don't retroactively change past deposits.
-- ------------------------------------------------------------
CREATE TABLE dbo.AdvancePaymentDeposit (
    DepositID       INT IDENTITY(1,1)  NOT NULL PRIMARY KEY,
    CustomerID      INT                NOT NULL
                        CONSTRAINT FK_Deposit_Customer REFERENCES dbo.Customer(CustomerID),
    DepositDate     DATE               NOT NULL DEFAULT CAST(GETDATE() AS DATE),
    Amount          DECIMAL(10,2)      NOT NULL CONSTRAINT CK_Deposit_Amount CHECK (Amount > 0),
    Channel         VARCHAR(20)        NOT NULL
                        CONSTRAINT CK_Deposit_Channel CHECK (Channel IN ('Cash','GCash')),
    ExpiryDate      DATE               NOT NULL
);
GO

CREATE INDEX IX_Deposit_Customer ON dbo.AdvancePaymentDeposit(CustomerID);
GO

-- ------------------------------------------------------------
-- 9. Helper views
-- ------------------------------------------------------------

-- Current advance-payment balance per customer.
-- NOTE: this is the "simple pooled balance" model you chose —
-- it sums deposits that have not yet expired and nets off every
-- Balance-funded transaction. Because it's pooled rather than
-- tracked per-deposit (FIFO), once a specific deposit's expiry
-- date passes, its full amount stops counting toward the pool —
-- there's no partial-attribution between which draw came from
-- which deposit. Fine for the current low-volume use case; flag
-- to revisit if members start stacking multiple overlapping
-- deposits with different expiry dates.
CREATE VIEW dbo.vw_CustomerBalance AS
SELECT
    c.CustomerID,
    c.CustomerName,
    ISNULL(dep.ActiveDeposits, 0) - ISNULL(spent.SpentFromBalance, 0) AS CurrentBalance
FROM dbo.Customer c
LEFT JOIN (
    SELECT CustomerID, SUM(Amount) AS ActiveDeposits
    FROM dbo.AdvancePaymentDeposit
    WHERE ExpiryDate >= CAST(GETDATE() AS DATE)
    GROUP BY CustomerID
) dep ON dep.CustomerID = c.CustomerID
LEFT JOIN (
    SELECT CustomerID, SUM(TotalAmount) AS SpentFromBalance
    FROM dbo.SalesTransaction
    WHERE FundingType = 'Balance'
    GROUP BY CustomerID
) spent ON spent.CustomerID = c.CustomerID;
GO

-- Open (unpaid) debts, with customer name for quick lookup
CREATE VIEW dbo.vw_OpenDebts AS
SELECT
    d.DebtID,
    d.TransactionID,
    c.CustomerName,
    d.AmountDue,
    d.DateIncurred,
    DATEDIFF(DAY, d.DateIncurred, GETDATE()) AS DaysOutstanding
FROM dbo.Debt d
JOIN dbo.SalesTransaction t ON t.TransactionID = d.TransactionID
JOIN dbo.Customer c ON c.CustomerID = t.CustomerID
WHERE d.Status = 'Unpaid';
GO

PRINT 'WaterStoreDB schema created successfully.';

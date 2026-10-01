/*
  SQLHealthLab - demo database with deliberate problems, so the health check
  has something real to find. DEMO ONLY - never run on production.
  Remove it with 99_drop_lab.sql.

  Problems created on purpose:
    - AUTO_SHRINK ON, AUTO_UPDATE_STATISTICS OFF, PAGE_VERIFY TORN_PAGE
    - Old compatibility level (110), FULL recovery with no backups
    - Log file with 10% growth
    - 300k-row heap queried without a supporting index (missing index + expensive query)
    - Index that is written but never read (unused index)
    - Statistics with 33% of rows modified (stale stats)
    - GUID clustered key inserted in batches (fragmented index)
*/
USE master;
GO
IF DB_ID(N'SQLHealthLab') IS NOT NULL
BEGIN
    ALTER DATABASE SQLHealthLab SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SQLHealthLab;
END
GO
CREATE DATABASE SQLHealthLab;
GO
ALTER DATABASE SQLHealthLab SET RECOVERY FULL;
ALTER DATABASE SQLHealthLab SET AUTO_SHRINK ON;
ALTER DATABASE SQLHealthLab SET AUTO_UPDATE_STATISTICS OFF;
ALTER DATABASE SQLHealthLab SET PAGE_VERIFY TORN_PAGE_DETECTION;
ALTER DATABASE SQLHealthLab SET COMPATIBILITY_LEVEL = 110;
ALTER DATABASE SQLHealthLab MODIFY FILE (NAME = N'SQLHealthLab_log', FILEGROWTH = 10%);
GO
USE SQLHealthLab;
GO
SET NOCOUNT ON;

-- 1) Heap with 300k orders
CREATE TABLE dbo.Orders (
    OrderId    int           NOT NULL,
    CustomerId int           NOT NULL,
    OrderDate  datetime      NOT NULL,
    Status     varchar(20)   NOT NULL,
    Amount     decimal(12,2) NOT NULL,
    Notes      char(200)     NOT NULL
);

;WITH n AS (
    SELECT TOP (300000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT dbo.Orders (OrderId, CustomerId, OrderDate, Status, Amount, Notes)
SELECT i,
       i % 5000,
       DATEADD(MINUTE, -i, '20260930'),
       CASE i % 4 WHEN 0 THEN 'NEW' WHEN 1 THEN 'PAID' WHEN 2 THEN 'SHIPPED' ELSE 'CANCELLED' END,
       (i % 1000) + 0.99,
       'order'
FROM n;
GO

-- 2) Index that is only written, never read
CREATE INDEX IX_Orders_Notes ON dbo.Orders (Notes);
UPDATE dbo.Orders SET Notes = 'updated' WHERE OrderId <= 5000;
GO

-- 3) Statistics that go stale (auto update is OFF)
CREATE STATISTICS st_Orders_Amount ON dbo.Orders (Amount) WITH FULLSCAN;
UPDATE dbo.Orders SET Amount = Amount + 1 WHERE OrderId % 3 = 0;
GO

-- 4) Fragmented clustered index (random GUID key, inserted in batches)
CREATE TABLE dbo.Events (
    EventId   uniqueidentifier NOT NULL CONSTRAINT PK_Events PRIMARY KEY CLUSTERED DEFAULT NEWID(),
    CreatedAt datetime2        NOT NULL DEFAULT SYSDATETIME(),
    Payload   char(300)        NOT NULL
);

DECLARE @b int = 0;
WHILE @b < 60
BEGIN
    INSERT dbo.Events (Payload)
    SELECT TOP (2000) 'event'
    FROM sys.all_objects a CROSS JOIN (SELECT 1 AS x UNION ALL SELECT 2) b;
    SET @b += 1;
END
GO

-- 5) Workload: repeated query that needs an index on (CustomerId, OrderDate)
DECLARE @k int = 0, @c int, @total decimal(18,2);
WHILE @k < 50
BEGIN
    SET @c = ABS(CHECKSUM(NEWID())) % 5000;
    EXEC sys.sp_executesql
        N'SELECT @t = SUM(Amount) FROM dbo.Orders WHERE CustomerId = @cust AND OrderDate >= @from',
        N'@cust int, @from datetime, @t decimal(18,2) OUTPUT',
        @cust = @c, @from = '20260901', @t = @total OUTPUT;
    SET @k += 1;
END
GO

PRINT 'SQLHealthLab ready. Now run sqlserver_healthcheck.sql';

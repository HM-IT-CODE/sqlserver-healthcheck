/*
================================================================================
  SQL Server Health Check  v1.0
  Author : Henry (github.com/HM-IT-CODE)
  License: MIT

  Read-only diagnostic for SQL Server 2017+ (2019 / 2022 / 2025).
  It does NOT change anything. Every fix is printed as a script for you to
  review and run yourself.

  Covers:
    - Instance configuration (memory, MAXDOP, cost threshold, ad hoc, IFI)
    - tempdb layout
    - Database options (auto-shrink, auto-close, page verify, stats, compat,
      Query Store, percent file growth)
    - Backups (last full / last log)
    - Wait statistics with interpretation
    - I/O latency per file
    - Memory pressure (PLE, memory grants pending)
    - Missing indexes (with generated CREATE INDEX)
    - Fragmented indexes, unused indexes, large heaps, stale statistics
    - Most expensive cached queries
    - Live blocking snapshot

  Required permissions: VIEW SERVER STATE, VIEW ANY DEFINITION,
  read on msdb, and access to each target database (sysadmin works).

  Usage: set @TargetDbs below and run in SSMS (Results to Grid).
================================================================================
*/
SET NOCOUNT ON;
USE master;

-------------------------------------------------------------------------------
-- PARAMETERS
-------------------------------------------------------------------------------
DECLARE @TargetDbs nvarchar(max) = N'WMS_SENTINEL_DEMO,SQLHealthLab'; -- comma list; NULL = all online user DBs
DECLARE @TopN      int           = 10;

-------------------------------------------------------------------------------
-- WORK TABLES
-------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
CREATE TABLE #Findings (
    Id             int IDENTITY(1,1) PRIMARY KEY,
    Severity       varchar(10)    NOT NULL,   -- HIGH / MEDIUM / LOW / INFO / OK
    Category       varchar(30)    NOT NULL,
    DatabaseName   sysname        NULL,
    CheckName      nvarchar(200)  NOT NULL,
    Detail         nvarchar(4000) NULL,
    Recommendation nvarchar(4000) NULL
);

IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
CREATE TABLE #Dbs (DatabaseId int PRIMARY KEY, DatabaseName sysname);

INSERT #Dbs (DatabaseId, DatabaseName)
SELECT d.database_id, d.name
FROM sys.databases d
WHERE d.database_id > 4
  AND d.state_desc = 'ONLINE'
  AND (@TargetDbs IS NULL
       OR d.name IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@TargetDbs, ',')));

IF OBJECT_ID('tempdb..#Heaps')    IS NOT NULL DROP TABLE #Heaps;
IF OBJECT_ID('tempdb..#Frag')     IS NOT NULL DROP TABLE #Frag;
IF OBJECT_ID('tempdb..#Unused')   IS NOT NULL DROP TABLE #Unused;
IF OBJECT_ID('tempdb..#Stats')    IS NOT NULL DROP TABLE #Stats;
CREATE TABLE #Heaps  (DatabaseName sysname, SchemaName sysname, TableName sysname, RowCnt bigint);
CREATE TABLE #Frag   (DatabaseName sysname, SchemaName sysname, TableName sysname, IndexName sysname NULL, FragPct float, PageCnt bigint);
CREATE TABLE #Unused (DatabaseName sysname, SchemaName sysname, TableName sysname, IndexName sysname, Writes bigint);
CREATE TABLE #Stats  (DatabaseName sysname, SchemaName sysname, TableName sysname, StatName sysname, RowCnt bigint, Mods bigint, LastUpdated datetime2 NULL);

-------------------------------------------------------------------------------
-- 0. SERVER INFO
-------------------------------------------------------------------------------
DECLARE @cpu int, @memMB bigint, @startTime datetime, @uptimeHours int, @verMajor int;

SELECT @cpu = cpu_count,
       @memMB = physical_memory_kb / 1024,
       @startTime = sqlserver_start_time
FROM sys.dm_os_sys_info;

SET @uptimeHours = DATEDIFF(HOUR, @startTime, GETDATE());
SET @verMajor    = CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));

IF @uptimeHours < 24
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('INFO', 'Server', NULL, 'Short uptime',
            CONCAT('SQL Server has been running for only ', @uptimeHours, ' hours.'),
            'Wait, index-usage and query statistics reset on restart. Re-run after a full business day for reliable numbers.');

-------------------------------------------------------------------------------
-- 1. INSTANCE CONFIGURATION
-------------------------------------------------------------------------------
DECLARE @maxMem bigint = (SELECT CONVERT(bigint, value_in_use) FROM sys.configurations WHERE name = 'max server memory (MB)');
DECLARE @maxdop int    = (SELECT CONVERT(int,    value_in_use) FROM sys.configurations WHERE name = 'max degree of parallelism');
DECLARE @ctfp   int    = (SELECT CONVERT(int,    value_in_use) FROM sys.configurations WHERE name = 'cost threshold for parallelism');
DECLARE @adhoc  int    = (SELECT CONVERT(int,    value_in_use) FROM sys.configurations WHERE name = 'optimize for ad hoc workloads');
DECLARE @suggestMem bigint = CASE WHEN @memMB <= 8192 THEN @memMB * 3 / 4 ELSE @memMB - (@memMB / 8) END;

IF @maxMem >= 2147483647
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('HIGH', 'Configuration', NULL, 'Max server memory not configured',
            CONCAT('max server memory is the default (unlimited). Physical RAM: ', @memMB, ' MB. SQL Server can starve the OS and cause paging.'),
            CONCAT('EXEC sp_configure ''show advanced options'',1; RECONFIGURE; EXEC sp_configure ''max server memory (MB)'',', @suggestMem, '; RECONFIGURE;'));
ELSE IF @maxMem > @memMB
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('MEDIUM', 'Configuration', NULL, 'Max server memory above physical RAM',
            CONCAT('max server memory = ', @maxMem, ' MB, physical RAM = ', @memMB, ' MB.'),
            CONCAT('Lower max server memory to around ', @suggestMem, ' MB.'));
ELSE
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('OK', 'Configuration', NULL, 'Max server memory configured',
            CONCAT('max server memory = ', @maxMem, ' MB of ', @memMB, ' MB physical.'), NULL);

IF @maxdop = 0 AND @cpu > 8
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('MEDIUM', 'Configuration', NULL, 'MAXDOP unlimited on a large server',
            CONCAT('MAXDOP = 0 with ', @cpu, ' logical CPUs. One query can take every core.'),
            'EXEC sp_configure ''max degree of parallelism'', 8; RECONFIGURE;  -- or cores per NUMA node, whichever is lower');
ELSE IF @maxdop = 0
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('LOW', 'Configuration', NULL, 'MAXDOP left at default (0)',
            CONCAT('MAXDOP = 0 with ', @cpu, ' logical CPUs.'),
            CONCAT('Consider EXEC sp_configure ''max degree of parallelism'', ', @cpu, '; RECONFIGURE; (set explicitly, review vendor requirements).'));
ELSE
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES (CASE WHEN @maxdop = 1 THEN 'INFO' ELSE 'OK' END, 'Configuration', NULL, 'MAXDOP set explicitly',
            CONCAT('MAXDOP = ', @maxdop, ' (', @cpu, ' logical CPUs).'),
            CASE WHEN @maxdop = 1 THEN 'MAXDOP 1 disables parallelism. Fine if the vendor requires it; otherwise large reports may run slower.' END);

IF @ctfp <= 5
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('MEDIUM', 'Configuration', NULL, 'Cost threshold for parallelism at default (5)',
            'Even cheap queries go parallel, wasting CPU and causing CXPACKET waits.',
            'EXEC sp_configure ''cost threshold for parallelism'', 50; RECONFIGURE;  -- starting point, tune from workload');
ELSE
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('OK', 'Configuration', NULL, 'Cost threshold for parallelism tuned', CONCAT('Value = ', @ctfp, '.'), NULL);

IF @adhoc = 0
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('LOW', 'Configuration', NULL, 'Optimize for ad hoc workloads is OFF',
            'Single-use plans fill the plan cache (common with ERP apps that build SQL strings).',
            'EXEC sp_configure ''optimize for ad hoc workloads'', 1; RECONFIGURE;');

DECLARE @ifi char(1) = (SELECT TOP 1 instant_file_initialization_enabled
                        FROM sys.dm_server_services
                        WHERE servicename LIKE 'SQL Server (%');
IF @ifi = 'N'
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('LOW', 'Configuration', NULL, 'Instant file initialization disabled',
            'Data file growth must zero-fill the new space, freezing the database during autogrowth.',
            'Grant the SQL Server service account "Perform volume maintenance tasks" (secpol.msc) and restart the service.');

-------------------------------------------------------------------------------
-- 2. TEMPDB
-------------------------------------------------------------------------------
DECLARE @tempFiles int, @tempMinMB bigint, @tempMaxMB bigint;
SELECT @tempFiles = COUNT(*), @tempMinMB = MIN(size) / 128, @tempMaxMB = MAX(size) / 128
FROM tempdb.sys.database_files
WHERE type = 0;

IF @tempFiles < CASE WHEN @cpu > 8 THEN 8 ELSE @cpu END
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('MEDIUM', 'tempdb', 'tempdb', 'Too few tempdb data files',
            CONCAT(@tempFiles, ' data file(s) for ', @cpu, ' logical CPUs. Causes allocation contention (PAGELATCH waits).'),
            CONCAT('Add data files up to ', CASE WHEN @cpu > 8 THEN 8 ELSE @cpu END, ', all the same size and growth.'));
ELSE
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('OK', 'tempdb', 'tempdb', 'tempdb data file count', CONCAT(@tempFiles, ' data files.'), NULL);

IF @tempMinMB <> @tempMaxMB
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('LOW', 'tempdb', 'tempdb', 'tempdb data files have different sizes',
            CONCAT('Smallest ', @tempMinMB, ' MB, largest ', @tempMaxMB, ' MB. Proportional fill will favor the biggest file.'),
            'Resize all tempdb data files to the same size and growth increment.');

-------------------------------------------------------------------------------
-- 3. DATABASE OPTIONS
-------------------------------------------------------------------------------
INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'MEDIUM', 'Database options', d.name, 'AUTO_SHRINK is ON',
       'Auto-shrink fragments every index and causes CPU/IO spikes at random times.',
       CONCAT('ALTER DATABASE ', QUOTENAME(d.name), ' SET AUTO_SHRINK OFF;')
FROM sys.databases d JOIN #Dbs t ON t.DatabaseId = d.database_id
WHERE d.is_auto_shrink_on = 1;

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'MEDIUM', 'Database options', d.name, 'AUTO_CLOSE is ON',
       'The database closes when the last user disconnects; the next user pays the startup cost and caches are flushed.',
       CONCAT('ALTER DATABASE ', QUOTENAME(d.name), ' SET AUTO_CLOSE OFF;')
FROM sys.databases d JOIN #Dbs t ON t.DatabaseId = d.database_id
WHERE d.is_auto_close_on = 1;

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'MEDIUM', 'Database options', d.name, 'PAGE_VERIFY is not CHECKSUM',
       CONCAT('Current setting: ', d.page_verify_option_desc, '. Corruption may go undetected.'),
       CONCAT('ALTER DATABASE ', QUOTENAME(d.name), ' SET PAGE_VERIFY CHECKSUM;')
FROM sys.databases d JOIN #Dbs t ON t.DatabaseId = d.database_id
WHERE d.page_verify_option_desc <> 'CHECKSUM';

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'MEDIUM', 'Database options', d.name, 'Automatic statistics disabled',
       CONCAT('AUTO_CREATE_STATISTICS = ', CASE d.is_auto_create_stats_on WHEN 1 THEN 'ON' ELSE 'OFF' END,
              ', AUTO_UPDATE_STATISTICS = ', CASE d.is_auto_update_stats_on WHEN 1 THEN 'ON' ELSE 'OFF' END,
              '. The optimizer works with outdated row estimates.'),
       CONCAT('ALTER DATABASE ', QUOTENAME(d.name), ' SET AUTO_CREATE_STATISTICS ON; ALTER DATABASE ', QUOTENAME(d.name), ' SET AUTO_UPDATE_STATISTICS ON;')
FROM sys.databases d JOIN #Dbs t ON t.DatabaseId = d.database_id
WHERE d.is_auto_create_stats_on = 0 OR d.is_auto_update_stats_on = 0;

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'LOW', 'Database options', d.name, 'Old compatibility level',
       CONCAT('Compatibility level ', d.compatibility_level, ' on a server that supports ', @verMajor * 10, '. Newer optimizer features are not used.'),
       'Test with the application vendor before raising it; enable Query Store first to catch regressions.'
FROM sys.databases d JOIN #Dbs t ON t.DatabaseId = d.database_id
WHERE d.compatibility_level < @verMajor * 10;

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'INFO', 'Database options', d.name, 'Query Store is OFF',
       'No history of query performance; regressions cannot be traced.',
       CONCAT('ALTER DATABASE ', QUOTENAME(d.name), ' SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);')
FROM sys.databases d JOIN #Dbs t ON t.DatabaseId = d.database_id
WHERE d.is_query_store_on = 0;

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'LOW', 'Database options', DB_NAME(mf.database_id), 'Percent-based file growth',
       CONCAT(mf.type_desc, ' file ', mf.name, ' grows by ', mf.growth, '%. Growth events get larger and slower over time.'),
       CONCAT('ALTER DATABASE ', QUOTENAME(DB_NAME(mf.database_id)), ' MODIFY FILE (NAME = ', QUOTENAME(mf.name), ', FILEGROWTH = ',
              CASE WHEN mf.type = 1 THEN '256MB' ELSE '512MB' END, ');')
FROM sys.master_files mf JOIN #Dbs t ON t.DatabaseId = mf.database_id
WHERE mf.is_percent_growth = 1;

-------------------------------------------------------------------------------
-- 4. BACKUPS
-------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Backups') IS NOT NULL DROP TABLE #Backups;
SELECT t.DatabaseName,
       d.recovery_model_desc AS RecoveryModel,
       b.LastFull,
       b.LastLog
INTO #Backups
FROM #Dbs t
JOIN sys.databases d ON d.database_id = t.DatabaseId
LEFT JOIN (
    SELECT database_name,
           MAX(CASE WHEN type = 'D' THEN backup_finish_date END) AS LastFull,
           MAX(CASE WHEN type = 'L' THEN backup_finish_date END) AS LastLog
    FROM msdb.dbo.backupset
    GROUP BY database_name
) b ON b.database_name = t.DatabaseName;

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'HIGH', 'Backups', DatabaseName, 'No recent full backup',
       CASE WHEN LastFull IS NULL THEN 'No full backup recorded in msdb.'
            ELSE CONCAT('Last full backup: ', CONVERT(varchar(16), LastFull, 120)) END,
       'Schedule a daily full backup (SQL Agent job or maintenance plan) and test a restore.'
FROM #Backups
WHERE LastFull IS NULL OR LastFull < DATEADD(DAY, -7, GETDATE());

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'HIGH', 'Backups', DatabaseName, 'FULL recovery without log backups',
       CASE WHEN LastLog IS NULL THEN 'Recovery model FULL but no log backup recorded. The transaction log will grow without limit.'
            ELSE CONCAT('Last log backup: ', CONVERT(varchar(16), LastLog, 120)) END,
       'Schedule log backups every 15-60 min, or switch to SIMPLE if point-in-time restore is not needed.'
FROM #Backups
WHERE RecoveryModel = 'FULL' AND (LastLog IS NULL OR LastLog < DATEADD(HOUR, -24, GETDATE()));

-------------------------------------------------------------------------------
-- 5. WAIT STATISTICS
-------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Waits') IS NOT NULL DROP TABLE #Waits;
SELECT wait_type, wait_time_ms, waiting_tasks_count, signal_wait_time_ms
INTO #Waits
FROM sys.dm_os_wait_stats
WHERE wait_time_ms > 0
  AND wait_type NOT LIKE 'SLEEP%'
  AND wait_type NOT LIKE 'XE%'
  AND wait_type NOT LIKE 'PREEMPTIVE%'
  AND wait_type NOT LIKE 'QDS%'
  AND wait_type NOT LIKE 'HADR%'
  AND wait_type NOT LIKE 'BROKER%'
  AND wait_type NOT LIKE 'PARALLEL_REDO%'
  AND wait_type NOT LIKE 'PWAIT%'
  AND wait_type NOT IN (
      'CHECKPOINT_QUEUE','CHKPT','CLR_AUTO_EVENT','CLR_MANUAL_EVENT','CLR_SEMAPHORE','CXCONSUMER',
      'DBMIRROR_DBM_EVENT','DBMIRROR_EVENTS_QUEUE','DBMIRROR_WORKER_QUEUE','DBMIRRORING_CMD',
      'DIRTY_PAGE_POLL','DISPATCHER_QUEUE_SEMAPHORE','EXECSYNC','FSAGENT','FT_IFTS_SCHEDULER_IDLE_WAIT',
      'FT_IFTSHC_MUTEX','KSOURCE_WAKEUP','LAZYWRITER_SLEEP','LOGMGR_QUEUE','MEMORY_ALLOCATION_EXT',
      'ONDEMAND_TASK_QUEUE','REDO_THREAD_PENDING_WORK','REQUEST_FOR_DEADLOCK_SEARCH','RESOURCE_QUEUE',
      'SERVER_IDLE_CHECK','SOS_WORK_DISPATCHER','SP_SERVER_DIAGNOSTICS_SLEEP','SQLTRACE_BUFFER_FLUSH',
      'SQLTRACE_INCREMENTAL_FLUSH_SLEEP','SQLTRACE_WAIT_ENTRIES','STARTUP_DEPENDENCY_MANAGER',
      'UCS_SESSION_REGISTRATION','VDI_CLIENT_OTHER','WAIT_FOR_RESULTS','WAIT_XTP_CKPT_CLOSE',
      'WAIT_XTP_HOST_WAIT','WAIT_XTP_OFFLINE_CKPT_NEW_LOG','WAIT_XTP_RECOVERY','WAITFOR',
      'WAITFOR_TASKSHUTDOWN','SOS_WORKER_MIGRATION','SNI_HTTP_ACCEPT');

DECLARE @topWait nvarchar(60), @topPct decimal(5,1);
SELECT TOP (1) @topWait = wait_type,
       @topPct = CAST(100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER (), 0) AS decimal(5,1))
FROM #Waits
ORDER BY wait_time_ms DESC;

IF @topWait IS NOT NULL
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES (
        CASE WHEN @topPct >= 40 AND (@topWait LIKE 'PAGEIOLATCH%' OR @topWait LIKE 'LCK_M%' OR @topWait IN
                  ('WRITELOG','CXPACKET','CXSYNC_PORT','CXSYNC_CONSUMER','SOS_SCHEDULER_YIELD','RESOURCE_SEMAPHORE','ASYNC_NETWORK_IO'))
             THEN 'MEDIUM' ELSE 'INFO' END,
        'Waits', NULL, CONCAT('Top wait: ', @topWait),
        CONCAT(@topWait, ' accounts for ', @topPct, '% of meaningful wait time since startup.'),
        CASE
            WHEN @topWait LIKE 'PAGEIOLATCH%' THEN 'Data pages read from disk. Check storage latency (section I/O), memory size and missing indexes that force table scans.'
            WHEN @topWait = 'WRITELOG' THEN 'Transaction log writes are slow. Put the log on fast storage; check VM disk latency.'
            WHEN @topWait IN ('CXPACKET','CXSYNC_PORT','CXSYNC_CONSUMER') THEN 'Parallelism overhead. Review MAXDOP and cost threshold for parallelism.'
            WHEN @topWait LIKE 'LCK_M%' THEN 'Sessions are blocking each other. Review long transactions; consider READ_COMMITTED_SNAPSHOT (test with vendor).'
            WHEN @topWait = 'SOS_SCHEDULER_YIELD' THEN 'CPU pressure. Tune the most expensive queries (Top Queries section) or add vCPUs.'
            WHEN @topWait = 'RESOURCE_SEMAPHORE' THEN 'Queries wait for memory grants. Add memory or fix queries with large sorts/hashes.'
            WHEN @topWait = 'ASYNC_NETWORK_IO' THEN 'SQL Server waits for the client to consume results: the application fetches large result sets row by row, or the network/terminal server is slow.'
            WHEN @topWait LIKE 'PAGELATCH%' THEN 'In-memory page contention, often tempdb allocation. Check tempdb file count.'
            ELSE 'Review this wait type against the workload.'
        END);

-------------------------------------------------------------------------------
-- 6. I/O LATENCY
-------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#IO') IS NOT NULL DROP TABLE #IO;
SELECT DB_NAME(vfs.database_id) AS DatabaseName,
       mf.name                  AS LogicalFile,
       mf.type_desc             AS FileType,
       vfs.num_of_reads         AS Reads,
       vfs.num_of_writes        AS Writes,
       CAST(vfs.io_stall_read_ms  * 1.0 / NULLIF(vfs.num_of_reads, 0)  AS decimal(10,1)) AS AvgReadMs,
       CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes, 0) AS decimal(10,1)) AS AvgWriteMs,
       CAST(mf.size / 128.0 AS decimal(18,1)) AS SizeMB
INTO #IO
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
JOIN sys.master_files mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
WHERE vfs.database_id = 2 OR vfs.database_id IN (SELECT DatabaseId FROM #Dbs);

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'MEDIUM', 'Storage', DatabaseName, 'High read latency on data file',
       CONCAT(LogicalFile, ': average read ', AvgReadMs, ' ms over ', Reads, ' reads (target < 20 ms).'),
       'Check the storage behind the VM (Hyper-V: VHDX on SSD, fixed size, no host contention).'
FROM #IO WHERE FileType = 'ROWS' AND Reads > 1000 AND AvgReadMs > 20;

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'MEDIUM', 'Storage', DatabaseName, 'High write latency on log file',
       CONCAT(LogicalFile, ': average write ', AvgWriteMs, ' ms over ', Writes, ' writes (target < 5-10 ms).'),
       'Every commit waits for the log. Move the log to faster storage.'
FROM #IO WHERE FileType = 'LOG' AND Writes > 1000 AND AvgWriteMs > 10;

-------------------------------------------------------------------------------
-- 7. MEMORY PRESSURE
-------------------------------------------------------------------------------
DECLARE @ple bigint = (SELECT TOP 1 cntr_value FROM sys.dm_os_performance_counters
                       WHERE counter_name = 'Page life expectancy' AND object_name LIKE '%Buffer Manager%');
DECLARE @grantsPending bigint = (SELECT TOP 1 cntr_value FROM sys.dm_os_performance_counters
                                 WHERE counter_name = 'Memory Grants Pending' AND object_name LIKE '%Memory Manager%');

IF @ple < 300
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('MEDIUM', 'Memory', NULL, 'Low page life expectancy',
            CONCAT('Pages stay in memory only ', @ple, ' seconds. Data is constantly re-read from disk.'),
            'Add memory to the VM / raise max server memory, or add indexes so queries read fewer pages.');
ELSE
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('OK', 'Memory', NULL, 'Page life expectancy', CONCAT(@ple, ' seconds.'), NULL);

IF @grantsPending > 0
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    VALUES ('MEDIUM', 'Memory', NULL, 'Memory grants pending',
            CONCAT(@grantsPending, ' queries are waiting for memory right now.'),
            'Find queries with large sorts/hashes; consider more memory.');

-------------------------------------------------------------------------------
-- 8. MISSING INDEXES
-------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Missing') IS NOT NULL DROP TABLE #Missing;
SELECT TOP (@TopN)
       DB_NAME(d.database_id) AS DatabaseName,
       d.statement            AS TableName,
       d.equality_columns     AS EqualityCols,
       d.inequality_columns   AS InequalityCols,
       d.included_columns     AS IncludedCols,
       gs.user_seeks + gs.user_scans AS TimesWanted,
       CAST(gs.avg_user_impact AS decimal(5,1)) AS AvgImpactPct,
       CAST(gs.avg_total_user_cost * gs.avg_user_impact * (gs.user_seeks + gs.user_scans) AS decimal(18,0)) AS Score,
       CONCAT('CREATE INDEX IX_HC_', d.index_handle, ' ON ', d.statement, ' (',
              ISNULL(d.equality_columns, ''),
              CASE WHEN d.equality_columns IS NOT NULL AND d.inequality_columns IS NOT NULL THEN ', ' ELSE '' END,
              ISNULL(d.inequality_columns, ''), ')',
              CASE WHEN d.included_columns IS NOT NULL THEN CONCAT(' INCLUDE (', d.included_columns, ')') ELSE '' END,
              ';') AS CreateStatement
INTO #Missing
FROM sys.dm_db_missing_index_details d
JOIN sys.dm_db_missing_index_groups g        ON g.index_handle = d.index_handle
JOIN sys.dm_db_missing_index_group_stats gs  ON gs.group_handle = g.index_group_handle
WHERE d.database_id IN (SELECT DatabaseId FROM #Dbs)
ORDER BY gs.avg_total_user_cost * gs.avg_user_impact * (gs.user_seeks + gs.user_scans) DESC;

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'MEDIUM', 'Indexes', DatabaseName, 'Missing index',
       CONCAT(TableName, ': requested ', TimesWanted, ' times, estimated ', AvgImpactPct, '% cost reduction.'),
       CONCAT(CreateStatement, '  -- validate against existing indexes before creating')
FROM #Missing
WHERE AvgImpactPct >= 50 AND TimesWanted >= 10;

-------------------------------------------------------------------------------
-- 9. PER-DATABASE CHECKS (heaps, fragmentation, unused indexes, statistics)
-------------------------------------------------------------------------------
DECLARE @db sysname, @sql nvarchar(max);
DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR SELECT DatabaseName FROM #Dbs;
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'USE ' + QUOTENAME(@db) + N';

    INSERT #Heaps (DatabaseName, SchemaName, TableName, RowCnt)
    SELECT DB_NAME(), s.name, t.name, SUM(p.rows)
    FROM sys.tables t
    JOIN sys.schemas s    ON s.schema_id = t.schema_id
    JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id = 0
    WHERE t.is_ms_shipped = 0
    GROUP BY s.name, t.name
    HAVING SUM(p.rows) > 10000;

    INSERT #Frag (DatabaseName, SchemaName, TableName, IndexName, FragPct, PageCnt)
    SELECT DB_NAME(), OBJECT_SCHEMA_NAME(ps.object_id), OBJECT_NAME(ps.object_id), i.name,
           ps.avg_fragmentation_in_percent, ps.page_count
    FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, NULL) ps
    JOIN sys.indexes i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
    WHERE ps.index_id > 0
      AND ps.page_count >= 1000
      AND ps.avg_fragmentation_in_percent >= 30
      AND ps.alloc_unit_type_desc = N''IN_ROW_DATA''
      AND OBJECTPROPERTY(ps.object_id, ''IsMsShipped'') = 0;

    INSERT #Unused (DatabaseName, SchemaName, TableName, IndexName, Writes)
    SELECT DB_NAME(), s.name, o.name, i.name, us.user_updates
    FROM sys.indexes i
    JOIN sys.objects o ON o.object_id = i.object_id
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    JOIN sys.dm_db_index_usage_stats us
         ON us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID()
    WHERE o.is_ms_shipped = 0
      AND i.type = 2
      AND i.is_primary_key = 0 AND i.is_unique = 0 AND i.is_unique_constraint = 0
      AND us.user_seeks + us.user_scans + us.user_lookups = 0
      AND us.user_updates > 0;

    INSERT #Stats (DatabaseName, SchemaName, TableName, StatName, RowCnt, Mods, LastUpdated)
    SELECT DB_NAME(), s.name, o.name, st.name, sp.rows, sp.modification_counter, sp.last_updated
    FROM sys.stats st
    JOIN sys.objects o ON o.object_id = st.object_id
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    CROSS APPLY sys.dm_db_stats_properties(st.object_id, st.stats_id) sp
    WHERE o.is_ms_shipped = 0
      AND sp.rows >= 1000
      AND sp.modification_counter >= sp.rows * 0.2;';

    BEGIN TRY
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
        VALUES ('INFO', 'Health check', @db, 'Database could not be fully analyzed', ERROR_MESSAGE(), 'Check permissions on this database.');
    END CATCH;

    FETCH NEXT FROM db_cur INTO @db;
END
CLOSE db_cur;
DEALLOCATE db_cur;

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'LOW', 'Indexes', DatabaseName, 'Large heap (no clustered index)',
       CONCAT(QUOTENAME(SchemaName), '.', QUOTENAME(TableName), ': ', RowCnt, ' rows without a clustered index.'),
       'Heaps suffer forwarded records and slow range scans. Consider a clustered index (check with the vendor).'
FROM #Heaps;

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'MEDIUM', 'Indexes', DatabaseName, 'Fragmented index',
       CONCAT(QUOTENAME(SchemaName), '.', QUOTENAME(TableName), ' / ', IndexName, ': ',
              CAST(FragPct AS decimal(5,1)), '% fragmented, ', PageCnt, ' pages.'),
       CONCAT('ALTER INDEX ', QUOTENAME(IndexName), ' ON ', QUOTENAME(DatabaseName), '.', QUOTENAME(SchemaName), '.', QUOTENAME(TableName),
              ' REBUILD;  -- schedule weekly index maintenance')
FROM #Frag;

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'LOW', 'Indexes', DatabaseName, 'Unused index (only writes)',
       CONCAT(QUOTENAME(SchemaName), '.', QUOTENAME(TableName), ' / ', IndexName, ': 0 reads, ', Writes, ' writes since last restart.'),
       'Costs write time with no read benefit. Confirm over a full business cycle (month-end reports) before dropping.'
FROM #Unused;

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'MEDIUM', 'Statistics', DatabaseName, 'Stale statistics',
       CONCAT(QUOTENAME(SchemaName), '.', QUOTENAME(TableName), ' / ', StatName, ': ', Mods, ' changes on ', RowCnt, ' rows (',
              CAST(100.0 * Mods / NULLIF(RowCnt, 0) AS decimal(6,1)), '%), last updated ', CONVERT(varchar(16), LastUpdated, 120), '.'),
       CONCAT('UPDATE STATISTICS ', QUOTENAME(DatabaseName), '.', QUOTENAME(SchemaName), '.', QUOTENAME(TableName), ' ', QUOTENAME(StatName), ' WITH FULLSCAN;')
FROM #Stats;

-------------------------------------------------------------------------------
-- 10. MOST EXPENSIVE CACHED QUERIES
-------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#TopQ') IS NOT NULL DROP TABLE #TopQ;
SELECT TOP (@TopN)
       DB_NAME(CONVERT(int, pa.value)) AS DatabaseName,
       qs.execution_count AS Executions,
       CAST(qs.total_worker_time / 1000.0 AS decimal(18,1))                         AS TotalCpuMs,
       CAST(qs.total_worker_time / 1000.0 / qs.execution_count AS decimal(18,2))    AS AvgCpuMs,
       CAST(qs.total_elapsed_time / 1000.0 / qs.execution_count AS decimal(18,2))   AS AvgDurationMs,
       qs.total_logical_reads / qs.execution_count                                  AS AvgLogicalReads,
       LEFT(REPLACE(REPLACE(SUBSTRING(st.text, qs.statement_start_offset / 2 + 1,
            (CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END
             - qs.statement_start_offset) / 2 + 1), CHAR(13), ' '), CHAR(10), ' '), 300) AS QueryText
INTO #TopQ
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) pa
WHERE pa.attribute = 'dbid'
  AND CONVERT(int, pa.value) IN (SELECT DatabaseId FROM #Dbs)
ORDER BY qs.total_worker_time DESC;

INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
SELECT 'MEDIUM', 'Queries', DatabaseName, 'Query with high logical reads',
       CONCAT(Executions, ' executions, ', AvgLogicalReads, ' pages read per execution, ', AvgDurationMs, ' ms avg. ', LEFT(QueryText, 120)),
       'Usually a scan caused by a missing index or non-sargable filter. See Missing Indexes and the query text in Top Queries.'
FROM #TopQ
WHERE AvgLogicalReads >= 5000 AND Executions >= 5;

-------------------------------------------------------------------------------
-- 11. LIVE BLOCKING SNAPSHOT
-------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Blocking') IS NOT NULL DROP TABLE #Blocking;
SELECT r.session_id AS SessionId, r.blocking_session_id AS BlockedBy, r.wait_type AS WaitType,
       r.wait_time AS WaitMs, DB_NAME(r.database_id) AS DatabaseName, LEFT(st.text, 200) AS QueryText
INTO #Blocking
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
WHERE r.blocking_session_id <> 0
  AND r.blocking_session_id <> r.session_id   -- parallel workers of the same query are not real blocking
  AND r.session_id <> @@SPID;                 -- exclude this health check itself

IF EXISTS (SELECT 1 FROM #Blocking)
    INSERT #Findings (Severity, Category, DatabaseName, CheckName, Detail, Recommendation)
    SELECT 'HIGH', 'Blocking', NULL, 'Active blocking right now',
           CONCAT(COUNT(*), ' session(s) blocked at the time of the check.'),
           'See the Blocking result set; identify the head blocker and its open transaction.'
    FROM #Blocking;

-------------------------------------------------------------------------------
-- OUTPUT
-------------------------------------------------------------------------------
-- 1) Server
SELECT 'SERVER' AS [Section],
       SERVERPROPERTY('ProductVersion') AS [Version],
       SERVERPROPERTY('Edition')        AS [Edition],
       @cpu         AS LogicalCPUs,
       @memMB       AS PhysicalMemoryMB,
       @startTime   AS SqlStartTime,
       @uptimeHours AS UptimeHours,
       (SELECT STRING_AGG(DatabaseName, ', ') FROM #Dbs) AS DatabasesAnalyzed;

-- 2) Score
SELECT 'SUMMARY' AS [Section], Severity, COUNT(*) AS Findings
FROM #Findings
GROUP BY Severity
ORDER BY CASE Severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 3 WHEN 'INFO' THEN 4 ELSE 5 END;

-- 3) Findings (the report)
SELECT Severity, Category, DatabaseName, CheckName, Detail, Recommendation
FROM #Findings
ORDER BY CASE Severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 3 WHEN 'INFO' THEN 4 ELSE 5 END,
         Category, Id;

-- 4) Detail: waits
SELECT TOP (@TopN) 'WAITS' AS [Section], wait_type AS WaitType,
       CAST(wait_time_ms / 1000.0 AS decimal(18,1)) AS WaitSeconds,
       CAST(100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER (), 0) AS decimal(5,1)) AS Pct,
       waiting_tasks_count AS Tasks,
       CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS decimal(18,1)) AS AvgWaitMs,
       CAST(100.0 * signal_wait_time_ms / NULLIF(wait_time_ms, 0) AS decimal(5,1)) AS SignalPct
FROM #Waits
ORDER BY wait_time_ms DESC;

-- 5) Detail: I/O
SELECT 'IO' AS [Section], * FROM #IO ORDER BY DatabaseName, FileType DESC;

-- 6) Detail: backups
SELECT 'BACKUPS' AS [Section], * FROM #Backups ORDER BY DatabaseName;

-- 7) Detail: missing indexes
SELECT 'MISSING INDEXES' AS [Section], * FROM #Missing ORDER BY Score DESC;

-- 8) Detail: top queries
SELECT 'TOP QUERIES' AS [Section], * FROM #TopQ ORDER BY TotalCpuMs DESC;

-- 9) Detail: blocking
SELECT 'BLOCKING' AS [Section], * FROM #Blocking;

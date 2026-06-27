-- ============================================================
-- seed.sql  –  Idempotent schema + sample data
--
-- Run automatically by null_resource.seed_db during terraform apply.
-- Authentication: ActiveDirectoryDefault (ambient az login session).
--
-- To run manually:
--   sqlcmd -S <sql_server_fqdn> -d sqldb-howden-dev-ins-01 \
--          --authentication-method=ActiveDirectoryDefault \
--          -i sql/seed.sql
--
-- Part 2 (granting the backend managed identity db_datareader access)
-- is handled inline by null_resource.seed_db in main.tf using the
-- actual container app name from Terraform state.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PolicyRecords' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE PolicyRecords (
        Id            INT IDENTITY(1,1) PRIMARY KEY,
        PolicyNumber  NVARCHAR(50)  NOT NULL,
        PolicyHolder  NVARCHAR(100) NOT NULL,
        PolicyType    NVARCHAR(50)  NOT NULL,
        Premium       DECIMAL(10,2) NOT NULL,
        StartDate     DATE          NOT NULL,
        EndDate       DATE          NOT NULL,
        Status        NVARCHAR(20)  NOT NULL
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM PolicyRecords)
BEGIN
    INSERT INTO PolicyRecords (PolicyNumber, PolicyHolder, PolicyType, Premium, StartDate, EndDate, Status)
    VALUES
        ('POL-2024-001', 'Alice Johnson',    'Motor',    1200.00, '2024-01-15', '2025-01-15', 'Active'),
        ('POL-2024-002', 'Bob Smith',        'Health',   3500.00, '2024-03-01', '2025-03-01', 'Active'),
        ('POL-2024-003', 'Carol Williams',   'Property', 2800.00, '2024-06-01', '2025-06-01', 'Active'),
        ('POL-2024-004', 'David Brown',      'Motor',     950.00, '2024-02-20', '2025-02-20', 'Active'),
        ('POL-2023-005', 'Emma Davis',       'Life',     5000.00, '2023-07-01', '2033-07-01', 'Active'),
        ('POL-2023-006', 'Frank Miller',     'Travel',    450.00, '2023-11-01', '2024-11-01', 'Expired'),
        ('POL-2024-007', 'Grace Wilson',     'Health',   2200.00, '2024-04-15', '2025-04-15', 'Active'),
        ('POL-2024-008', 'Henry Moore',      'Property', 3100.00, '2024-08-01', '2025-08-01', 'Active'),
        ('POL-2024-009', 'Isabella Taylor',  'Motor',    1450.00, '2024-09-10', '2025-09-10', 'Active'),
        ('POL-2024-010', 'James Anderson',   'Life',     7500.00, '2024-05-01', '2034-05-01', 'Active');
END
GO

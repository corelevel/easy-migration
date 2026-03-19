# Easy-Migration
A lightweight PowerShell-based SQL Server migration runner that executes database migration scripts in a defined order and keeps track of executed scripts. The tool supports running both DML and DDL migration scripts and it is designed as a simple alternative to heavy migration frameworks. 

The tool ensures migrations are:
- Executed only once
- Protected against script modifications
- Run in a deterministic order

One note I wanted to add - based on my experience, as a best practice, all migrations should be idempotent, allowing scripts to be executed safely multiple times, including manual execution when required.

## Features
- Simple JSON configuration
- Ordered migration execution
- Script checksum validation
- Migration history tracking
- Phase-based deployments
- Script skipping support
- Script forcing support
- Dry-run mode

## Requirements
PowerShell with the [SQL Server module](https://learn.microsoft.com/en-us/powershell/sql-server/download-sql-server-ps-module) installed. To install it just run:
```powershell
Install-Module SqlServer
```

## Versions
- *functions-ps7.0.ps1* - PowerShell 7+ the latest and greatest
    - Uses modern [Microsoft.Data.SqlClient](https://learn.microsoft.com/en-us/sql/connect/ado-net/introduction-microsoft-data-sqlclient-namespace)
- *functions-ps5.1.ps1* - PowerShell 5.1+
    - Uses *System.Data.SqlClient*

## Migration History Table
The tool stores executed migrations in *dbo.easy_migration_history* table. 

Add this table to source control for the target database to prevent it from being accidentally dropped by CI/CD.

## Project Structure
Example directory layout:
```
migrations
│
├─ migration.json
│
├─ phase01
│   ├─ 000-fix.sql
│   ├─ 001-delete-old.sql
│   └─ job007
│        └─ 000-kill-all-user-processes.sql
│
├─ phase02
│   └─ 000-do-stuff.sql
│
└─ phase03
    └─ 000-fix-this.sql
```

## Configuration File
Migration order is defined in *migration.json*. Example:
```javascript
{
    "phase01": {
        "scripts": [
            "000-fix-this.sql",
            "001-fix-that.sql",
            "job007\\000-kill-all-user-processes.sql"
        ]
    },
    "phase02": {
        "scripts": [
            "000-do-cool-stuff.sql"
        ]
    },
    "phase03": {
        "scripts": [
            "000-fix-this.sql"
        ]
    }
}
```

## Parameters
- *ConnStr* - SQL Server connection string
- *BasePath* - folder containing config file and migration scripts
- *Phase* - migration phase to execute
- *IgnoreScripts* - optional list of scripts to skip during execution
- *ForceScripts* - optional list of migration script filenames to force execution even if they were previously recorded in the migration history table

## Dry Run
The script supports [-WhatIf](https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess) feature for safe preview. This will:
- Show which migration scripts would run
- Not execute any migration scripts

## Usage
- Create *dbo.easy_migration_history* table in the target database using *schema.sql* script
    - And don't forget to add it to source control for the target database
- Run *Invoke-EasyMigration*:
```powershell
Invoke-EasyMigration `
	-ConnStr "Data Source=(local);Initial Catalog=tempdb;Connection Timeout=5;
        Encrypt=False;Integrated Security=True;Application Name=easy-migration;" `
	-BasePath ".\migrations" `
	-Phase "phase01"
```

## CI/CD Integration
*Invoke-EasyMigration* can be easily integrated into CI/CD pipelines:
- GitHub Actions
- Azure DevOps
- Jenkins
- GitLab CI

Typical pipeline step:
```powershell
Invoke-EasyMigration `
    -ConnStr $env:DB_CONNECTION `
    -BasePath ".\migrations" `
    -Phase "phase01"
```

## License
[MIT License](http://en.wikipedia.org/wiki/MIT_License)
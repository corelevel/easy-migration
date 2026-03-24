using namespace Microsoft.Data.SqlClient

function Get-FileChecksum {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string]$File
	)

	(Get-FileHash -Path $File -Algorithm SHA256).Hash
}

function Get-RelativePath {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string]$RelativeTo,

		[Parameter(Mandatory)]
		[string]$Path
	)
	[System.IO.Path]::GetRelativePath($RelativeTo, $Path)
}

function Get-Executed {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string]$ConnStr,

		[Parameter(Mandatory)]
		[string]$Phase
	)

	$sqlConn = $null
	$sqlCmd = $null
	$sqlReader = $null

	try {
		$sqlConn = [SQLConnection]::new()
		$sqlConn.ConnectionString = $ConnStr
		$query = @'
select script_name, [checksum]
from dbo.easy_migration_history
where phase = @phase
'@

		$sqlConn.Open()
		$sqlCmd = [SqlCommand]::new($query, $sqlConn)
		$sqlCmd.CommandType = [System.Data.CommandType]::Text
		$pPhase = $sqlCmd.Parameters.Add('@phase', [System.Data.SqlDbType]::NVarChar, 32)
		$pPhase.Value = $Phase
		$sqlReader = $sqlCmd.ExecuteReader()

		if ($sqlReader.HasRows) {
			while ($sqlReader.Read()) {
				[PSCustomObject]@{
					script_name = $sqlReader['script_name'].ToLower()
					checksum = $sqlReader['checksum']
				}
			}
		}
	}
	finally {
		if ($sqlReader) {
			$sqlReader.Close()
			$sqlReader.Dispose()
		}
		if ($sqlCmd) {
			$sqlCmd.Dispose()
		}
		if ($sqlConn) {
			$sqlConn.Close()
			$sqlConn.Dispose()
		}
	}
}

function Set-Executed {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string]$ConnStr,

		[Parameter(Mandatory)]
		[string]$ScriptName,

		[Parameter(Mandatory)]
		[string]$Phase,

		[Parameter(Mandatory)]
		[string]$Checksum,

		[Parameter(Mandatory)]
		[bool]$ForceScript
	)

	$sqlConn = $null
	$sqlCmd = $null

	try {
		$sqlConn = [SQLConnection]::new()
		$sqlConn.ConnectionString = $ConnStr

		$query = ''
		if ($ForceScript) {
			$query = @'
update dbo.easy_migration_history
set [checksum] = @checksum, executed_at = sysutcdatetime()
where script_name = @script_name and phase = @phase

if @@rowcount = 0
begin
	raiserror('Forced execution failed. The script was not found in the migration history table',16,1)
end
'@
		}
		else {
			$query = @'
insert dbo.easy_migration_history(script_name, phase, [checksum])
values(@script_name, @phase, @checksum)
'@
		}

		$sqlConn.Open()
		$sqlCmd = [SqlCommand]::new($query, $sqlConn)
		$sqlCmd.CommandType = [System.Data.CommandType]::Text
		$pScriptName = $sqlCmd.Parameters.Add('@script_name', [System.Data.SqlDbType]::NVarChar)
		$pScriptName.Value = $ScriptName
		$pPhase = $sqlCmd.Parameters.Add('@phase', [System.Data.SqlDbType]::NVarChar, 32)
		$pPhase.Value = $Phase
		$pChecksum = $sqlCmd.Parameters.Add('@checksum', [System.Data.SqlDbType]::Char, 64)
		$pChecksum.Value = $Checksum
		$sqlCmd.ExecuteNonQuery() | Out-Null # Out-Null to suppress the output
	}
	finally {
		if ($sqlCmd) {
			$sqlCmd.Dispose()
		}
		if ($sqlConn) {
			$sqlConn.Close()
			$sqlConn.Dispose()
		}
	}
}

function Invoke-Migration {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string]$ConnStr,

		[Parameter(Mandatory)]
		[string]$Script
	)

	try {
		Invoke-Sqlcmd -ConnectionString $ConnStr -InputFile $Script -AbortOnError | Out-Null
	}
	catch {
		Write-Error "Failed to run migration script: $Script"
		throw
	}
}

function Get-Migrations {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string]$ConfigFile,

		[Parameter(Mandatory)]
		[string]$Phase
	)

	$json = Get-Content $ConfigFile -Raw | ConvertFrom-Json
	$first = $json.PSObject.Properties.Match($Phase)
	if (-not $first -or $first.Count -eq 0) {
		throw "Migration phase not found: $Phase"
	}

	$first[0].Value.scripts | ForEach-Object { $_.ToLower() }
}

function Invoke-EasyMigration {
	<#
	.SYNOPSIS
		Deploys migration scripts to the target SQL Server

	.DESCRIPTION
		Deploys migration scripts to the target SQL Server in order
		Detects checksum drift and stops on mismatch

		Requires PowerShell 7+
		Requires SQL Server PowerShell module
		https://learn.microsoft.com/en-us/powershell/sql-server/download-sql-server-ps-module

	.PARAMETER ConnStr
		SQL Server connection string

	.PARAMETER BasePath
		Folder containing config file and migration scripts

	.PARAMETER Phase
		Migration phase to execute

	.PARAMETER IgnoreScripts
		Optional list of scripts to skip during execution
		Filenames must match entries defined in the configuration file
		Example: "001-fix-that.sql", "000-fix-this.sql"

	.PARAMETER ForceScripts
		Optional list of migration script filenames to force execution even if
			they were previously recorded in the migration history table
		Filenames must match entries defined in the configuration file
		Example: "job007\000-kill-all-user-processes.sql"

	.INPUTS
		{
			"phase01": {
				"scripts": [
					"001-fix-that.sql",
					"000-fix-this.sql",
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
	#>

	[CmdletBinding(SupportsShouldProcess = $true)]
	param (
		[Parameter(Mandatory)]
		[string]$ConnStr,

		[Parameter(Mandatory)]
		[ValidateScript({ Test-Path $_ -PathType Container })]
		[string]$BasePath,

		[Parameter(Mandatory)]
		[string]$Phase,

		[string[]]$IgnoreScripts,

		[string[]]$ForceScripts
	)

	Set-StrictMode -Version Latest

	try {
		$configFile = Join-Path $BasePath 'migration.json'
		$scriptsFolder = Join-Path $BasePath $Phase

		if (-not (Test-Path $configFile -PathType Leaf)) {
			throw "Migration configuration not found: $configFile"
		}

		if (-not (Test-Path $scriptsFolder -PathType Container)) {
			throw "Scripts folder not found: $scriptsFolder"
		}

		$executedScriptList = @(Get-Executed -ConnStr $ConnStr -Phase $Phase)
		$scriptList = @(Get-Migrations -ConfigFile $configFile -Phase $Phase)
		
		# Converting provided migration script lists to lower case
		if ($IgnoreScripts) {
			$IgnoreScripts = $IgnoreScripts | ForEach-Object { $_.ToLower() }
		}
		if ($ForceScripts) {
			$ForceScripts = $ForceScripts | ForEach-Object { $_.ToLower() }
		}

		# Check for duplicates
		$duplicates = $scriptList | Group-Object | Where-Object Count -gt 1
		if ($duplicates) {
			$names = ($duplicates | Select-Object -ExpandProperty Name) -join ', '
			throw "Duplicate script names detected in configuration: $names"
		}
		# Check for intersection
		if ($IgnoreScripts -and $ForceScripts) {
			$names = $IgnoreScripts | Where-Object { $_ -in $ForceScripts }
			if ($names) {
				throw "Scripts cannot be both ignored and forced: $($names -join ', ')"
			}
		}

		$dryRun = $true
		$connStrParser = [SqlConnectionStringBuilder]::new($ConnStr)
		$target = "DataSource: $($connStrParser.DataSource), InitialCatalog: " +
			"$($connStrParser.InitialCatalog), Phase: $Phase"

		if ($PSCmdlet.ShouldProcess($target)) {
			$dryRun = $false
		}
		else {
			Write-Verbose 'Dry run'
		}

		$executedScriptMap = @{}
		foreach ($script in $executedScriptList) {
			$executedScriptMap[$script.script_name] = $script.checksum
		}

		if ($IgnoreScripts) {
			$notPresent = $IgnoreScripts | Where-Object { $_ -notin $scriptList }
			if ($notPresent) {
				Write-Warning "IgnoreScripts contains names not present in configuration: " +
					"$($notPresent -join ', ')"
			}
		}

		if ($ForceScripts) {
			$notPresent = $ForceScripts | Where-Object { $_ -notin $scriptList }
			if ($notPresent) {
				Write-Warning "ForceScripts contains names not present in configuration: " +
					"$($notPresent -join ', ')"
			}
		}

		$didGoodJob = $false
		foreach ($scriptName in $scriptList) {
			if ($IgnoreScripts) {
				if ($IgnoreScripts.Contains($scriptName)) {
					Write-Verbose "Ignoring migration script: $scriptName"
					continue
				}
			}

			$forceScript = $false
			if ($ForceScripts) {
				if ($ForceScripts.Contains($scriptName)) {
					Write-Verbose "Forcing migration script: $scriptName"
					$forceScript = $true
				}
			}

			$scriptFullPath = Join-Path $scriptsFolder $scriptName
			if (-not (Test-Path $scriptFullPath -PathType Leaf)) {
				throw "Migration script not found: $scriptFullPath"
			}

			$scriptExecuted = $executedScriptMap.ContainsKey($scriptName)
			# Check for checksum difference
			$checksum = Get-FileChecksum -File $scriptFullPath
			if (-not $forceScript -and $scriptExecuted) {
				$executedChecksum = $executedScriptMap[$scriptName]
				if ($checksum -ne $executedChecksum) {
					throw "Checksum mismatch for migration script: $scriptName"
				}
				continue
			}

			$didGoodJob = $true
			Write-Verbose "Running migration script: $scriptName"
			if (-not $dryRun) {
				Invoke-Migration -ConnStr $ConnStr -Script $scriptFullPath

				$scriptName = Get-RelativePath -RelativeTo $scriptsFolder -Path $scriptFullPath
				Set-Executed -ConnStr $ConnStr -ScriptName $scriptName -Phase $Phase.ToLower() `
					-Checksum $checksum -ForceScript ($forceScript -and $scriptExecuted)
			}
			Write-Verbose 'Migration completed'
		}

		if (-not $didGoodJob) {
			Write-Verbose 'Nothing to run'
		}
		else {
			Write-Verbose 'Easy as that!'
		}
	}
	catch {
		Write-Error "Failed to run migration: $_"
		throw
	}
}

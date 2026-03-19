# For PowerShell 7.0+
. (Join-Path $PSScriptRoot ".." "functions-ps7.0.ps1")

# For PowerShell 5.1+
#. (Join-Path (Join-Path $PSScriptRoot "..") "functions-ps5.1.ps1")

Invoke-EasyMigration `
	-ConnStr "Data Source=(local);Initial Catalog=tempdb;Connection Timeout=5;Encrypt=False;
		User Id=sa;Password=P1s-Unsee-Me;Application Name=easy-migration;" `
	-BasePath $PSScriptRoot `
	-Phase "phase01" `
	-ForceScripts "job007\000-kill-all-user-processes.sql" `
	-Verbose `
	#-WhatIf
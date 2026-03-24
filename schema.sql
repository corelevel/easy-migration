if not exists (
	select	1
	from	INFORMATION_SCHEMA.TABLES
	where TABLE_SCHEMA = N'dbo' and TABLE_NAME = N'easy_migration_history' and TABLE_TYPE = N'BASE TABLE')
begin
	create table dbo.easy_migration_history
	(
		script_name		nvarchar(255) not null,
		[checksum]		char(64) not null,
		phase			nvarchar(32) not null,
		executed_at		datetime2(7) constraint DF_easy_migration_history__executed_at default (sysutcdatetime()) not null
	)

	alter table dbo.easy_migration_history add constraint PK_easy_migration_history primary key clustered (phase, script_name)
	with (data_compression = page)
end
go
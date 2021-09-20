declare 	@TimeLimit int = 43200,		-- the amount of time we want to limit the restores - the default is 12 hours
    @exec BIT = 1

	SET NOCOUNT ON
	DECLARE @fileSearch nvarchar(500) = '',
		@backupFile nvarchar(500),
		@data_dir nvarchar(100) , 
		@cmd nvarchar(max),
		@dropCmd nvarchar(500),
		@RestoredDBName sysname,
		@backupPath NVARCHAR(500) = '',
		@error nvarchar(600),
		@recipients varchar(2000),
		@profile_name sysname,
		@backup_file_server varchar(2000)
		;

	SELECT @data_dir = DataDirectory
	, @recipients = NotifyEmailAddressList
	, @profile_name = DBMailProfile
	, @backup_file_server = BackupFileServer
	FROM dbo.DatabaseRestoreConfig
	WHERE Id = 1

	-- Set the time we started the restore process so we know when we want to exit 
	-- if it hits the TimeLimit, we'll stop for the day
	DECLARE @StartTime datetime
	SET @StartTime = GETDATE()

	--DECLARE @fileList Table (rowNumber int identity(1,1), backupFile nvarchar(255), backupPath nvarchar(500));
	DECLARE @fileList Table (rowNumber int identity(1,1), backupFile nvarchar(255), depth int, [isfile] bit);

	DECLARE @FileListTable Table (
		[LogicalName] nvarchar(128),
		[PhysicalName] nvarchar(260), 
		[Type] char(1), 
		[FileGroupName] nvarchar(128), 
		[Size] numeric(20,0),
		[MaxSize] numeric(20,0), 
		[FileId] bigint, 
		[CreateLSN] numeric(25,0), 
		[DropLSN] numeric(25,0), 
		[UniqueId] uniqueidentifier, 
		[ReadOnlyLSN] numeric(25,0), 
		[ReadWriteLSN] numeric(25,0),
		[BackupSizeInBytes] bigint, 
		[SourceBlockSize] int, 
		[FileGroupId] int, 
		[LogGroupGUID] uniqueidentifier, 
		[DifferentialBaseLSN] numeric(25,0), 
		[DifferentialBaseGUID] uniqueidentifier, 
		[IsReadOnly] bit, 
		[IsPresent] bit, 
		[TDEThumbprint] varbinary(32), 
		[SnapshotUrl] nvarchar(360));

	DECLARE @BackupHeader TABLE 
	(
		 BackupName nvarchar(128)
		,BackupDescription nvarchar(255)
		,BackupType smallint
		,ExpirationDate datetime
		,Compressed tinyint
		,Position smallint
		,DeviceType tinyint
		,UserName nvarchar(128)
		,ServerName nvarchar(128)
		,DatabaseName nvarchar(128)
		,DatabaseVersion int
		,DatabaseCreationDate datetime
		,BackupSize numeric(20,0)
		,FirstLSN numeric(25,0)
		,LastLSN numeric(25,0)
		,CheckpointLSN numeric(25,0)
		,DatabaseBackupLSN numeric(25,0)
		,BackupStartDate datetime
		,BackupFinishDate datetime
		,SortOrder smallint
		,CodePage smallint
		,UnicodeLocaleId int
		,UnicodeComparisonStyle int
		,CompatibilityLevel tinyint
		,SoftwareVendorId int
		,SoftwareVersionMajor int
		,SoftwareVersionMinor int
		,SoftwareVersionBuild int
		,MachineName nvarchar(128)
		,Flags int
		,BindingID uniqueidentifier
		,RecoveryForkID uniqueidentifier
		 --following columns introduced in SQL 2008
		,Collation nvarchar(128)
		,FamilyGUID uniqueidentifier
		,HasBulkLoggedData bit
		,IsSnapshot bit
		,IsReadOnly bit
		,IsSingleUser bit
		,HasBackupChecksums bit
		,IsDamaged bit
		,BeginsLogChain bit
		,HasIncompleteMetaData bit
		,IsForceOffline bit
		,IsCopyOnly bit
		,FirstRecoveryForkID uniqueidentifier
		,ForkPointLSN numeric(25,0)
		,RecoveryModel nvarchar(60)
		,DifferentialBaseLSN numeric(25,0)
		,DifferentialBaseGUID uniqueidentifier
		,BackupTypeDescription nvarchar(60)
		,BackupSetGUID uniqueidentifier NULL 
		,CompressedBackupSize bigint
		--following columns introduced in SQL 2012
		,Containment tinyint 
		--following columns introduced in SQL 2014
		,KeyAlgorithm nvarchar(32)
		,EncryptorThumbprint varbinary(20)
		,EncryptorType nvarchar(32)
	);
	DECLARE @backupFiles TABLE (BackupFile nvarchar(500), BackupSetGUID uniqueidentifier, BackupFinishDate datetime2(7))

	DECLARE @database_id int
	DECLARE @database_name sysname
	DECLARE @ag_name nvarchar(100)
	DECLARE @last_restore_date date

	-- loop through the list of databases
	-- restore them, then run DBCC checks on them
	
	WHILE GETDATE() < DATEADD(ss,@TimeLimit,@StartTime)
	BEGIN
		-- grab the oldest databases that haven't been restored recently
		SELECT TOP 1 @database_id = d.Id, 
            @database_name = d.Name, 
            @ag_name = d.AvailabilityGroup, 
            @last_restore_date = drl.LastRestoredDate
		FROM DatabasesToRestore d
		LEFT JOIN
		(
			-- get the last date each database was restored
			SELECT 
				DatabaseId,
				LastRestoredDate = MAX(RestoredDate)
			FROM DatabaseRestoreLog
			GROUP BY DatabaseId
		) drl
			ON d.Id = drl.DatabaseId
		WHERE d.IsActive = 1
			AND (drl.LastRestoredDate <> CAST(GETDATE() AS DATE) 
			    OR drl.LastRestoredDate IS NULL)
		ORDER BY drl.LastRestoredDate 

		IF @@ROWCOUNT = 0
          BEGIN
            BREAK
          END

		PRINT CONCAT('Restoring : ', @database_name, ' in AG ', @ag_name, ' last restored date: ', @last_restore_date)

		
		SET @backupPath = CONCAT(@backup_file_server, '\', @database_name, '\FULL_COPY_ONLY\')
		PRINT @backupPath

		--SET @fileSearch = 'DIR *.bak /b /O:D ' + @backupPath;
		INSERT INTO @fileList (backupFile, depth, isfile)
		EXEC xp_DirTree @backupPath, 1,1
		
		--Get last backup from @fileList
		DECLARE @C int = 1
		WHILE @C <= (SELECT MAX(rowNumber) FROM @fileList)
		BEGIN
			DELETE FROM @BackupHeader
			SELECT @backupFile = backupFile FROM @fileList
			WHERE isfile = 1 and @c = rowNumber

			SELECT @cmd = CONCAT('RESTORE HEADERONLY FROM DISK = ''',@backupPath, '\',@backupFile,'''')
			PRINT @cmd
			INSERT INTO @BackupHeader
			EXEC (@cmd)
			SET @C= @C+1
			INSERT INTO @backupFiles (BackupFile,BackupFinishDate, BackupSetGUID)
			SELECT @backupFile,  BackupFinishDate, BackupSetGUID
			FROM @BackupHeader 

		END
		--only consider the most recent backup set
		DELETE FROM @backupFiles WHERE BackupFinishDate != (
			SELECT MAX(BackupFinishDate) FROM @backupFiles
		)

		SELECT Top 1 @backupFile = backupFile FROM @backupFiles ORDER BY BackupFile
		IF @backupFile Is Not Null
			BEGIN
				DECLARE @fullPath nvarchar(500) = @backupPath + @backupFile;
				PRINT 'Backup File Found: ' + @fullPath;

				INSERT INTO @FileListTable
				EXEC('Restore FileListOnly From Disk = ''' + @fullPath + '''');

				SET @RestoredDBName = REPLACE(@backupFile, '.bak', '')

				-- insert into the log the Database we're restoring
				INSERT INTO dbo.[DatabaseRestoreLog] (DatabaseId, RestoredName, RestoredDate, RestoreStartTime)
				VALUES (@database_id, @RestoredDBName, GETDATE(), GETDATE());

				SET @cmd = 'Restore Database [' + @RestoredDBName + '] From'  
				--Add multiple backup file support
				SELECT @cmd = @cmd + char(13) + ' Disk = ''' + @backupPath + BackupFile + ''','
				FROM @backupFiles
				PRINT @cmd
				--remove trailing comma
				SELECT SUBSTRING(@cmd, 1,len(@cmd)-1)
				PRINT @cmd
				SELECT @cmd = @cmd + ' With File = 1, ' + char(13);
				
				--add move clause
				SELECT @cmd = @cmd + '  Move N''' + LogicalName + ''' To N''' + @data_dir + LogicalName + '_' + @RestoredDBName + '.' +
					REVERSE(SUBSTRING(REVERSE(PhysicalName), 0, CHARINDEX('.', REVERSE(PhysicalName),0))) + ''', ' + char(13)
				FROM @FileListTable

				SET @cmd = @cmd + '  NoUnload, Stats = 5;' + char(13);
				SET @cmd = @cmd + 'Alter Database [' + @RestoredDBName + '] Set Recovery Simple With No_Wait;'

				-- if for some reason the database with the restored name exists, drop it first
				IF EXISTS (SELECT 1 
							FROM sys.databases 
							WHERE Name = @RestoredDBName)
					BEGIN
						PRINT 'Dropping existing [' + @RestoredDBName +']';
						SET @dropCmd = 'Alter Database [' + @RestoredDBName + '] Set Single_User With Rollback Immediate; Drop Database [' + @RestoredDBName + '];';
						PRINT(@dropCmd);

						IF @exec = 1 
							EXEC(@dropCmd);
					END

				-- if it doesn't exist, then restore the database
				PRINT 'Restoring [' + @database_name + '] from ' + @backupFile;
				PRINT(@cmd);
				IF @exec = 1 
					EXEC(@cmd);




				-- make sure the DB exists before trying to run DBCC CHECKDB on it
				IF EXISTS (SELECT 1 FROM sys.databases WHERE Name = @RestoredDBName) 
					BEGIN
						-- When the restore is complete, update the Log to reflect the end time
						UPDATE dbo.DatabaseRestoreLog
						SET RestoreEndTime = GETDATE(),
							DBCCStartTime = GETDATE()
						WHERE DatabaseId = @database_id
							AND RestoredName = @RestoredDBName

						EXEC dbo.spRunDBCCChecks @dbName = @RestoredDBName, @exec = @exec;

						-- When the DBCC Check is complete, update the Log to reflect the end time
						UPDATE dbo.DatabaseRestoreLog
						SET DBCCEndTime = GETDATE()
						WHERE DatabaseId = @database_id
							AND RestoredName = @RestoredDBName
					END
				ELSE 
					-- if the restore failed, then raise an error that it failed and send an emails
					BEGIN
						SET @error = 'Restore of database ''' + @RestoredDBName + ''' failed. Check the log on the server.' ;
						-- send an email alert to that the DBCC CHECKDB failed for the restored item
						--EXEC msdb.dbo.sp_send_dbmail @profile_name =  @profile_name, @recipients = @recipients, @subject = @error, @body = @error;
						RAISERROR(@error, 18, 1);
					END

			END
		ELSE
			BEGIN
				SET @error = 'No Recent backup was found in ''' + @backupPath + '''';
				RAISERROR(@error, 18, 1);
			END

		-- delete the info on the one we just restored
		DELETE FROM @fileList
		DELETE FROM @FileListTable
	END
	/*
	Move this to it's own job
	-- once we're done, let's clear out the DBCC_History_Log table a bit, cause it grows fast
	DELETE
	FROM dbo.DBCC_History_Log
	WHERE DBCCCheckDate < GETDATE() - 30;
	*/
	-- send an email to sql-alerts with a count of what was done and what passed
	DECLARE @TotalDatabasesRestored int 
	DECLARE @TotalPassedCheck int 

	SELECT 
		@TotalDatabasesRestored = count(*),
		@TotalPassedCheck = count(case when PassedDBCCChecks = 1 then DatabaseId end)
	FROM dbo.DatabaseRestoreLog
	WHERE RestoredDate = CAST(GETDATE() as date)

	DECLARE @subject nvarchar(100) = CONCAT('Database restore results for ', cast(getdate() as date))
	DECLARE @body nvarchar(500) = CONCAT('Total Databases Restored: ', @TotalDatabasesRestored, 'Total Databases Passing DBCC Check:',  @TotalPassedCheck)
	/*
	EXEC msdb.dbo.sp_send_dbmail @profile_name =  @profile_name , 
		@recipients = @recipients, 
		@subject = @subject, 
		@body = @body;

	*/
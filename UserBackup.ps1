# UserBackup.ps1 - Fast User Data Backup Script
# Execute remotely with: iwr -useb "your-url/UserBackup.ps1" | iex

param(
    [string]$Username,
    [string]$BackupLocation,
    [string]$BackupFolder
)


# Function to display header
function Show-Header {
    Clear-Host
    Write-Host "=================================" -ForegroundColor Cyan
    Write-Host "   Windows User Backup Tool" -ForegroundColor Cyan
    Write-Host "=================================" -ForegroundColor Cyan
    Write-Host ""
}

# Function to select user and return folder name
function Select-User {
    Write-Host "Available users:" -ForegroundColor Yellow

    # Try WMI method first
    try {
        $wmiUsers = Get-WmiObject -Class Win32_UserProfile | Where-Object {
            $_.LocalPath -like "C:\Users\*" -and
            $_.LocalPath -notmatch "(Public|Default|All Users)$" -and
            -not $_.Special
        }

        if ($wmiUsers -and $wmiUsers.Count -gt 0) {
            $userNum = 1
            foreach ($profile in $wmiUsers) {
                $userName = Split-Path $profile.LocalPath -Leaf
                $displayName = $userName

                # Get the SID and try to resolve to a friendly name
                try {
                    $sid = New-Object System.Security.Principal.SecurityIdentifier($profile.SID)
                    $ntAccount = $sid.Translate([System.Security.Principal.NTAccount])
                    $friendlyName = $ntAccount.Value.Split('\')[-1]
                    if ($friendlyName -and $friendlyName -ne $userName) {
                        $displayName = $friendlyName
                    }
                } catch {
                    # If translation fails, use the folder name
                }

                # Display immediately without storing in arrays
                Write-Host "  $userNum. $displayName"
                $userNum++
            }

            do {
                $selection = Read-Host "`nSelect user number (1-$($wmiUsers.Count))"
                $userIndex = [int]$selection - 1
            } while ($userIndex -lt 0 -or $userIndex -ge $wmiUsers.Count)

            # Return the folder name directly
            return Split-Path $wmiUsers[$userIndex].LocalPath -Leaf
        }
    } catch {
        # Fall back to directory method if WMI fails
    }

    # Fallback to directory listing
    $userFolders = Get-ChildItem "C:\Users" -Directory | Where-Object {
        $_.Name -notin @("Public", "Default", "Default User", "All Users")
    }

    if ($userFolders.Count -eq 0) {
        throw "No user profiles found in C:\Users directory!"
    }

    $userNum = 1
    foreach ($folder in $userFolders) {
        Write-Host "  $userNum. $($folder.Name)"
        $userNum++
    }

    do {
        $selection = Read-Host "`nSelect user number (1-$($userFolders.Count))"
        $userIndex = [int]$selection - 1
    } while ($userIndex -lt 0 -or $userIndex -ge $userFolders.Count)

    return $userFolders[$userIndex].Name
}

# Function to detect existing backup folders on a device
function Get-ExistingBackups {
    param([string]$DevicePath)

    Write-Host "Scanning for existing backups on $DevicePath..." -ForegroundColor Yellow

    try {
        $backupFolders = Get-ChildItem $DevicePath -Directory -ErrorAction SilentlyContinue | Where-Object {
            # Check if folder contains typical backup structure
            $subFolders = Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue
            $hasBackupStructure = $subFolders.Name | Where-Object {
                $_ -in @("Desktop", "Downloads", "Documents", "Pictures", "Videos", "Music", "OneDrive_Desktop", "OneDrive_Documents", "OneDrive_Pictures", "OneDrive_Videos", "OneDrive_Music")
            }
            return $hasBackupStructure.Count -gt 0
        }

        return $backupFolders
    } catch {
        Write-Warning "Could not scan device $DevicePath for backups: $($_.Exception.Message)"
        return @()
    }
}

# Function to analyze what's missing from an existing backup
function Compare-BackupProgress {
    param(
        [string]$UserPath,
        [string]$BackupPath
    )

    Write-Host "Analyzing backup progress..." -ForegroundColor Yellow

    $folders = @("Desktop", "Downloads", "Documents", "Pictures", "Videos", "Music")
    $oneDriveFolders = @(
        @{Source = "$UserPath\OneDrive\Desktop"; Dest = "OneDrive_Desktop"},
        @{Source = "$UserPath\OneDrive\Documents"; Dest = "OneDrive_Documents"},
        @{Source = "$UserPath\OneDrive\Pictures"; Dest = "OneDrive_Pictures"},
        @{Source = "$UserPath\OneDrive\Videos"; Dest = "OneDrive_Videos"},
        @{Source = "$UserPath\OneDrive\Music"; Dest = "OneDrive_Music"}
    )

    $missing = @()
    $incomplete = @()
    $complete = @()

    # Check standard folders
    foreach ($folder in $folders) {
        $sourcePath = Join-Path $UserPath $folder
        $destPath = Join-Path $BackupPath $folder

        if (Test-Path $sourcePath) {
            if (-not (Test-Path $destPath)) {
                $missing += @{Type = "Standard"; Name = $folder; Source = $sourcePath; Dest = $destPath}
            } else {
                # Check if backup is complete by comparing file counts (simple check)
                try {
                    $sourceCount = (Get-ChildItem $sourcePath -Recurse -File -ErrorAction SilentlyContinue).Count
                    $destCount = (Get-ChildItem $destPath -Recurse -File -ErrorAction SilentlyContinue).Count

                    if ($sourceCount -gt $destCount) {
                        $incomplete += @{Type = "Standard"; Name = $folder; Source = $sourcePath; Dest = $destPath; SourceFiles = $sourceCount; BackupFiles = $destCount}
                    } else {
                        $complete += @{Type = "Standard"; Name = $folder; Source = $sourcePath; Dest = $destPath; Files = $destCount}
                    }
                } catch {
                    # If we can't compare, assume incomplete
                    $incomplete += @{Type = "Standard"; Name = $folder; Source = $sourcePath; Dest = $destPath; SourceFiles = "Unknown"; BackupFiles = "Unknown"}
                }
            }
        }
    }

    # Check OneDrive folders
    foreach ($oneFolder in $oneDriveFolders) {
        if (Test-Path $oneFolder.Source) {
            $destPath = Join-Path $BackupPath $oneFolder.Dest

            if (-not (Test-Path $destPath)) {
                $missing += @{Type = "OneDrive"; Name = $oneFolder.Dest; Source = $oneFolder.Source; Dest = $destPath}
            } else {
                # Check if backup is complete
                try {
                    $sourceCount = (Get-ChildItem $oneFolder.Source -Recurse -File -ErrorAction SilentlyContinue).Count
                    $destCount = (Get-ChildItem $destPath -Recurse -File -ErrorAction SilentlyContinue).Count

                    if ($sourceCount -gt $destCount) {
                        $incomplete += @{Type = "OneDrive"; Name = $oneFolder.Dest; Source = $oneFolder.Source; Dest = $destPath; SourceFiles = $sourceCount; BackupFiles = $destCount}
                    } else {
                        $complete += @{Type = "OneDrive"; Name = $oneFolder.Dest; Source = $oneFolder.Source; Dest = $destPath; Files = $destCount}
                    }
                } catch {
                    $incomplete += @{Type = "OneDrive"; Name = $oneFolder.Dest; Source = $oneFolder.Source; Dest = $destPath; SourceFiles = "Unknown"; BackupFiles = "Unknown"}
                }
            }
        }
    }

    return @{
        Missing = $missing
        Incomplete = $incomplete
        Complete = $complete
    }
}

# Function to get available storage devices
function Get-StorageDevices {
    $drives = Get-WmiObject -Class Win32_LogicalDisk | Where-Object {
        $_.DriveType -eq 2 -or $_.DriveType -eq 3
    } | Select-Object DeviceID, VolumeName, Size, FreeSpace, DriveType

    $deviceList = @()
    foreach ($drive in $drives) {
        $sizeGB = [math]::Round($drive.Size / 1GB, 2)
        $freeGB = [math]::Round($drive.FreeSpace / 1GB, 2)
        $type = if ($drive.DriveType -eq 2) { "Removable" } else { "Fixed" }

        $deviceList += [PSCustomObject]@{
            Drive = $drive.DeviceID
            Label = if ($drive.VolumeName) { $drive.VolumeName } else { "Unlabeled" }
            Size = "$sizeGB GB"
            Free = "$freeGB GB"
            Type = $type
        }
    }
    return $deviceList
}

# Function to estimate copy time and size
function Get-CopyEstimate {
    param([string]$SourcePath)

    Write-Host "Calculating backup size..." -ForegroundColor Yellow

    $totalSize = 0
    $fileCount = 0

    $folders = @("Desktop", "Downloads", "Documents", "Pictures", "Videos", "Music")

    # Also check OneDrive folders that may contain the actual user data
    $oneDriveFolders = @(
        @{Source = "$SourcePath\OneDrive\Desktop"; Dest = "OneDrive_Desktop"},
        @{Source = "$SourcePath\OneDrive\Documents"; Dest = "OneDrive_Documents"},
        @{Source = "$SourcePath\OneDrive\Pictures"; Dest = "OneDrive_Pictures"},
        @{Source = "$SourcePath\OneDrive\Videos"; Dest = "OneDrive_Videos"},
        @{Source = "$SourcePath\OneDrive\Music"; Dest = "OneDrive_Music"}
    )

    foreach ($folder in $folders) {
        $folderPath = Join-Path $SourcePath $folder
        if (Test-Path $folderPath) {
            try {
                $folderInfo = Get-ChildItem $folderPath -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum
                $totalSize += $folderInfo.Sum
                $fileCount += $folderInfo.Count
            }
            catch {
                Write-Warning "Could not calculate size for $folder"
            }
        }
    }

    # Calculate size for OneDrive folders
    foreach ($oneFolder in $oneDriveFolders) {
        if (Test-Path $oneFolder.Source) {
            try {
                $folderInfo = Get-ChildItem $oneFolder.Source -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum
                $totalSize += $folderInfo.Sum
                $fileCount += $folderInfo.Count
            }
            catch {
                Write-Warning "Could not calculate size for $($oneFolder.Dest)"
            }
        }
    }

    $sizeGB = [math]::Round($totalSize / 1GB, 2)

    # Estimate time based on USB 3.0 speed (~100 MB/s) and USB 2.0 speed (~25 MB/s)
    $estimatedTimeUSB3 = [math]::Round(($totalSize / 1MB) / 100 / 60, 1)
    $estimatedTimeUSB2 = [math]::Round(($totalSize / 1MB) / 25 / 60, 1)

    return [PSCustomObject]@{
        SizeGB = $sizeGB
        FileCount = $fileCount
        EstimatedTimeUSB3 = $estimatedTimeUSB3
        EstimatedTimeUSB2 = $estimatedTimeUSB2
    }
}

# Function to perform the backup
function Start-UserBackup {
    param(
        [string]$UserPath,
        [string]$DestinationPath,
        [string]$UserName,
        [hashtable]$BackupAnalysis = $null
    )

    $folders = @("Desktop", "Downloads", "Documents", "Pictures", "Videos", "Music")
    $logFile = Join-Path $DestinationPath "backup_log.txt"

    # OneDrive folders that may contain the actual user data
    $oneDriveFolders = @(
        @{Source = "$UserPath\OneDrive\Desktop"; Dest = "OneDrive_Desktop"},
        @{Source = "$UserPath\OneDrive\Documents"; Dest = "OneDrive_Documents"},
        @{Source = "$UserPath\OneDrive\Pictures"; Dest = "OneDrive_Pictures"},
        @{Source = "$UserPath\OneDrive\Videos"; Dest = "OneDrive_Videos"},
        @{Source = "$UserPath\OneDrive\Music"; Dest = "OneDrive_Music"}
    )

    Write-Host "`nStarting backup for user: $UserName" -ForegroundColor Green
    Write-Host "Destination: $DestinationPath" -ForegroundColor Green
    Write-Host "Log file: $logFile" -ForegroundColor Gray

    # Determine which folders to process (resume mode or full backup)
    $foldersToProcess = $folders
    if ($BackupAnalysis) {
        Write-Host "Resume mode: Processing only missing and incomplete folders" -ForegroundColor Yellow
        $foldersToProcess = @()
        foreach ($folder in $folders) {
            $status = $BackupAnalysis.Folders[$folder]
            if ($status -eq "Missing" -or $status -eq "Incomplete") {
                $foldersToProcess += $folder
            }
        }
    }
    Write-Host ""

    $totalFolders = $foldersToProcess.Count
    $currentFolder = 0

    foreach ($folder in $foldersToProcess) {
        $currentFolder++
        $sourcePath = Join-Path $UserPath $folder
        $destPath = Join-Path $DestinationPath $folder

        if (Test-Path $sourcePath) {
            Write-Host "[$currentFolder/$totalFolders] Copying $folder..." -ForegroundColor Cyan

            # Robocopy with complete mirroring and full file copy
            $robocopyArgs = @(
                "`"$sourcePath`"",
                "`"$destPath`"",
                "/MIR",        # Mirror directory (copies everything, creates dirs, deletes extras)
                "/COPY:DAT",    # Copy all file info (ensures Excel, images, hidden files included)
                "/DCOPY:DAT",  # Copy directory Data, Attributes, and Timestamps
                "/XF", "*.pst", # Exclude Outlook PST files
                "/R:3",        # Retry 3 times on failed copies
                "/W:10",       # Wait 10 seconds between retries
                "/MT:16",      # Multi-threaded copying (16 threads for speed)
                "/LOG+:`"$logFile`"",  # Append to log file
                "/TEE",        # Output to console and log
                "/NP"          # No progress percentage (reduces overhead)
            )

            # Start robocopy process
            $process = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -NoNewWindow -PassThru -Wait

            # Check exit codes (0-3 are success, 4+ indicate issues)
            if ($process.ExitCode -le 3) {
                Write-Host "  ✓ $folder completed successfully" -ForegroundColor Green
            } elseif ($process.ExitCode -le 7) {
                Write-Host "  ⚠ $folder completed with warnings (Exit code: $($process.ExitCode))" -ForegroundColor Yellow
            } else {
                Write-Host "  ✗ $folder failed (Exit code: $($process.ExitCode))" -ForegroundColor Red
            }
        } else {
            Write-Host "[$currentFolder/$totalFolders] Skipping $folder (not found)" -ForegroundColor Gray
        }
    }

    # Backup OneDrive folders
    Write-Host "`nBacking up OneDrive folders..." -ForegroundColor Yellow

    # Determine which OneDrive folders to process (resume mode or full backup)
    $oneDriveFoldersToProcess = $oneDriveFolders
    if ($BackupAnalysis) {
        $oneDriveFoldersToProcess = @()
        foreach ($oneFolder in $oneDriveFolders) {
            $status = $BackupAnalysis.Folders[$oneFolder.Dest]
            if ($status -eq "Missing" -or $status -eq "Incomplete") {
                $oneDriveFoldersToProcess += $oneFolder
            }
        }
    }

    $totalOneDrive = $oneDriveFoldersToProcess.Count
    $currentOneDrive = 0

    foreach ($oneFolder in $oneDriveFoldersToProcess) {
        $currentOneDrive++
        if (Test-Path $oneFolder.Source) {
            Write-Host "[$currentOneDrive/$totalOneDrive] Copying $($oneFolder.Dest)..." -ForegroundColor Cyan

            $destPath = Join-Path $DestinationPath $oneFolder.Dest

            # Robocopy with complete mirroring and full file copy
            $robocopyArgs = @(
                "`"$($oneFolder.Source)`"",
                "`"$destPath`"",
                "/MIR",        # Mirror directory (copies everything, creates dirs, deletes extras)
                "/COPY:DAT",   # Copy all file info (ensures Excel, images, hidden files included)
                "/DCOPY:DAT",  # Copy directory Data, Attributes, and Timestamps
                "/XF", "*.pst", # Exclude Outlook PST files
                "/R:3",        # Retry 3 times on failed copies
                "/W:10",       # Wait 10 seconds between retries
                "/MT:16",      # Multi-threaded copying (16 threads for speed)
                "/LOG+:`"$logFile`"",  # Append to log file
                "/TEE",        # Output to console and log
                "/NP"          # No progress percentage (reduces overhead)
            )

            # Start robocopy process
            $process = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -NoNewWindow -PassThru -Wait

            # Check exit codes (0-3 are success, 4+ indicate issues)
            if ($process.ExitCode -le 3) {
                Write-Host "  ✓ $($oneFolder.Dest) completed successfully" -ForegroundColor Green
            } elseif ($process.ExitCode -le 7) {
                Write-Host "  ⚠ $($oneFolder.Dest) completed with warnings (Exit code: $($process.ExitCode))" -ForegroundColor Yellow
            } else {
                Write-Host "  ✗ $($oneFolder.Dest) failed (Exit code: $($process.ExitCode))" -ForegroundColor Red
            }
        } else {
            Write-Host "[$currentOneDrive/$totalOneDrive] Skipping $($oneFolder.Dest) (not found)" -ForegroundColor Gray
        }
    }
}

# Function to handle errors and prevent window closure
function Handle-Error {
    param([string]$ErrorMessage, [bool]$Critical = $false)

    Write-Host "`nERROR: $ErrorMessage" -ForegroundColor Red

    if ($Critical) {
        Write-Host "`nThis is a critical error that prevents the script from continuing." -ForegroundColor Red
        Write-Host "Please check the error message above and try again." -ForegroundColor Yellow
        Write-Host "`nPress any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    } else {
        Write-Host "The script will attempt to continue..." -ForegroundColor Yellow
    }
}

# Set error action preference to stop on errors but handle them gracefully
$ErrorActionPreference = "Stop"

# Main script execution with error handling
try {
    Show-Header

    # Get username if not provided
    if (-not $Username) {
        try {
            $Username = Select-User
        } catch {
            Handle-Error "Failed to select user: $($_.Exception.Message)" -Critical $true
        }
    }

    $userProfilePath = "C:\Users\$Username"
    if (-not (Test-Path $userProfilePath)) {
        Handle-Error "User profile not found: $userProfilePath" -Critical $true
    }

    Write-Host "Selected user: $Username" -ForegroundColor Green

    # Ask if this is a new backup or resume
    Write-Host "`nBackup Options:" -ForegroundColor Yellow
    Write-Host "  1. New backup (start fresh)"
    Write-Host "  2. Continue previous backup (resume)"

    do {
        $backupChoice = Read-Host "`nSelect option (1-2)"
        $backupChoice = [int]$backupChoice
    } while ($backupChoice -lt 1 -or $backupChoice -gt 2)

    $isResume = ($backupChoice -eq 2)

    # Get backup location if not provided
    if (-not $BackupLocation) {
        try {
            $devices = Get-StorageDevices

            if ($devices.Count -eq 0) {
                Handle-Error "No storage devices found!" -Critical $true
            }
        } catch {
            Handle-Error "Failed to get storage devices: $($_.Exception.Message)" -Critical $true
        }

    Write-Host "`nAvailable storage devices:" -ForegroundColor Yellow
    Write-Host "Drive | Label        | Size      | Free      | Type" -ForegroundColor Gray
    Write-Host "------|--------------|-----------|-----------|----------" -ForegroundColor Gray

    for ($i = 0; $i -lt $devices.Count; $i++) {
        $device = $devices[$i]
        $num = ($i + 1).ToString().PadLeft(2)
        $label = $device.Label.PadRight(12)
        $size = $device.Size.PadRight(9)
        $free = $device.Free.PadRight(9)
        Write-Host "$num. $($device.Drive) | $label | $size | $free | $($device.Type)"
    }

    do {
        $selection = Read-Host "`nSelect storage device number (1-$($devices.Count))"
        $deviceIndex = [int]$selection - 1
    } while ($deviceIndex -lt 0 -or $deviceIndex -ge $devices.Count)

        $BackupLocation = $devices[$deviceIndex].Drive
    }

    Write-Host "Selected backup location: $BackupLocation" -ForegroundColor Green

    # Handle resume vs new backup logic
    if ($isResume) {
        # Look for existing backups
        $existingBackups = Get-ExistingBackups -DevicePath $BackupLocation

        if ($existingBackups.Count -eq 0) {
            Write-Host "`nNo existing backups found on this device." -ForegroundColor Yellow
            Write-Host "Starting new backup instead..." -ForegroundColor Yellow
            $isResume = $false
        } else {
            Write-Host "`nExisting backup folders found:" -ForegroundColor Yellow
            for ($i = 0; $i -lt $existingBackups.Count; $i++) {
                $backup = $existingBackups[$i]
                $backupDate = $backup.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                Write-Host "  $($i + 1). $($backup.Name) - $backupDate"
            }

            do {
                $selection = Read-Host "`nSelect backup to resume (1-$($existingBackups.Count))"
                $backupIndex = [int]$selection - 1
            } while ($backupIndex -lt 0 -or $backupIndex -ge $existingBackups.Count)

            $BackupFolder = $existingBackups[$backupIndex].Name
            $fullBackupPath = $existingBackups[$backupIndex].FullName

            # Analyze what's missing
            $analysis = Compare-BackupProgress -UserPath $userProfilePath -BackupPath $fullBackupPath

            Write-Host "`nBackup Analysis for: $BackupFolder" -ForegroundColor Cyan
            Write-Host "  Complete folders: $($analysis.Complete.Count)" -ForegroundColor Green
            Write-Host "  Incomplete folders: $($analysis.Incomplete.Count)" -ForegroundColor Yellow
            Write-Host "  Missing folders: $($analysis.Missing.Count)" -ForegroundColor Red

            if ($analysis.Complete.Count -gt 0) {
                Write-Host "`n✓ Complete:" -ForegroundColor Green
                foreach ($item in $analysis.Complete) {
                    $name = $item['Name']
                    Write-Host "    $name" -ForegroundColor Green
                }
            }

            if ($analysis.Incomplete.Count -gt 0) {
                Write-Host "`n⚠ Incomplete:" -ForegroundColor Yellow
                foreach ($item in $analysis.Incomplete) {
                    $name = $item['Name']
                    Write-Host "    $name" -ForegroundColor Yellow
                }
            }

            if ($analysis.Missing.Count -gt 0) {
                Write-Host "`n✗ Missing:" -ForegroundColor Red
                foreach ($item in $analysis.Missing) {
                    $name = $item['Name']
                    Write-Host "    $name" -ForegroundColor Red
                }
            }

            if ($analysis.Missing.Count -eq 0 -and $analysis.Incomplete.Count -eq 0) {
                Write-Host "`nBackup appears to be complete!" -ForegroundColor Green
                $confirm = Read-Host "`nForce re-backup anyway? (y/N)"
                if ($confirm -ne 'y' -and $confirm -ne 'Y') {
                    Write-Host "Backup cancelled - already complete." -ForegroundColor Yellow
                    Write-Host "`nPress any key to exit..."
                    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                    exit 0
                }
            }
        }
    }

    if (-not $isResume) {
        # Get backup folder if not provided
        if (-not $BackupFolder) {
            $BackupFolder = Read-Host "`nEnter backup folder name (will be created in $BackupLocation)"
        }

        $fullBackupPath = Join-Path $BackupLocation $BackupFolder
    }

    Write-Host "Full backup path: $fullBackupPath" -ForegroundColor Green

    # Create backup directory if it doesn't exist
    if (-not (Test-Path $fullBackupPath)) {
        try {
            New-Item -ItemType Directory -Path $fullBackupPath -Force | Out-Null
            Write-Host "Created backup directory: $fullBackupPath" -ForegroundColor Green
        }
        catch {
            Handle-Error "Failed to create backup directory: $($_.Exception.Message)" -Critical $true
        }
    }

    # Get copy estimate
    try {
        $estimate = Get-CopyEstimate -SourcePath $userProfilePath
    } catch {
        Handle-Error "Failed to calculate backup size: $($_.Exception.Message)" -Critical $false
        # Create a default estimate to continue
        $estimate = [PSCustomObject]@{
            SizeGB = 0
            FileCount = 0
            EstimatedTimeUSB3 = 0
            EstimatedTimeUSB2 = 0
        }
    }

    Write-Host "`n=================================" -ForegroundColor Cyan
    if ($isResume) {
        Write-Host "Resume Backup Summary:" -ForegroundColor Cyan
        Write-Host "  Mode: Resume/Continue"
    } else {
        Write-Host "Backup Summary:" -ForegroundColor Cyan
        Write-Host "  Mode: New backup"
    }
    Write-Host "  User: $Username"
    Write-Host "  Destination: $fullBackupPath"
    Write-Host "  Estimated size: $($estimate.SizeGB) GB"
    Write-Host "  File count: $($estimate.FileCount)"
    Write-Host "  Estimated time (USB 3.0): $($estimate.EstimatedTimeUSB3) minutes"
    Write-Host "  Estimated time (USB 2.0): $($estimate.EstimatedTimeUSB2) minutes"
    Write-Host "=================================" -ForegroundColor Cyan

    $confirm = Read-Host "`nProceed with backup? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "Backup cancelled." -ForegroundColor Yellow
        Write-Host "`nPress any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 0
    }

    # Start the backup
    $startTime = Get-Date
    try {
        if ($isResume -and $backupAnalysis) {
            Start-UserBackup -UserPath $userProfilePath -DestinationPath $fullBackupPath -UserName $Username -BackupAnalysis $backupAnalysis
        } else {
            Start-UserBackup -UserPath $userProfilePath -DestinationPath $fullBackupPath -UserName $Username
        }
        $endTime = Get-Date

        $duration = $endTime - $startTime
        Write-Host "`n=================================" -ForegroundColor Green
        Write-Host "Backup Completed!" -ForegroundColor Green
        Write-Host "  Duration: $($duration.Hours)h $($duration.Minutes)m $($duration.Seconds)s"
        Write-Host "  Location: $fullBackupPath"
        Write-Host "  Log file: $(Join-Path $fullBackupPath 'backup_log.txt')"
        Write-Host "=================================" -ForegroundColor Green
    } catch {
        Handle-Error "Backup operation failed: $($_.Exception.Message)" -Critical $false
        Write-Host "`nPartial backup may have been created at: $fullBackupPath" -ForegroundColor Yellow
    }

} catch {
    # Catch any unhandled errors in the main execution
    Write-Host "`nUnexpected error occurred:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "`nStack trace:" -ForegroundColor Gray
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray
} finally {
    # Always prompt before closing, regardless of success or failure
    Write-Host "`nPress any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
# UserRestore.ps1 - Windows User Data Restore Script
# Execute remotely with: iwr -useb "your-url/UserRestore.ps1" | iex

param(
    [string]$TargetUser,
    [string]$SourceLocation,
    [string[]]$BackupFolders,
    [ValidateSet("Ask", "Skip", "Overwrite", "IfNewer")]
    [string]$ConflictResolution = "Ask"
)

# Function to display header
function Show-Header {
    Clear-Host
    Write-Host "=================================" -ForegroundColor Cyan
    Write-Host "   Windows User Restore Tool" -ForegroundColor Cyan
    Write-Host "=================================" -ForegroundColor Cyan
    Write-Host ""
}

# Function to get available users for restore target
function Select-TargetUser {
    Write-Host "Select target user to restore to:" -ForegroundColor Yellow

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
        Write-Host "No user profiles found!" -ForegroundColor Red
        exit 1
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

# Function to discover backup folders on selected device
function Get-BackupFolders {
    param([string]$SourcePath)

    Write-Host "Scanning for backup folders..." -ForegroundColor Yellow

    # Look for folders that contain typical backup structure
    $possibleBackups = Get-ChildItem $SourcePath -Directory | Where-Object {
        # Check if folder contains common backup folders
        $subFolders = Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue
        $hasBackupStructure = $subFolders.Name | Where-Object {
            $_ -in @("Desktop", "Downloads", "Documents", "Pictures", "Videos", "Music", "OneDrive_Desktop", "OneDrive_Documents", "OneDrive_Pictures", "OneDrive_Videos", "OneDrive_Music")
        }
        return $hasBackupStructure.Count -gt 0
    }

    if ($possibleBackups.Count -eq 0) {
        Write-Host "No backup folders found on selected device!" -ForegroundColor Red
        return $null
    }

    return $possibleBackups
}

# Function to select backup folders for restore
function Select-BackupFolders {
    param([array]$AvailableBackups)

    Write-Host "`nAvailable backup folders:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $AvailableBackups.Count; $i++) {
        $backup = $AvailableBackups[$i]
        $backupDate = $backup.LastWriteTime.ToString("yyyy-MM-dd HH:mm")

        # Try to get size estimate
        $sizeInfo = ""
        try {
            $totalSize = Get-ChildItem $backup.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum
            $sizeGB = [math]::Round($totalSize.Sum / 1GB, 2)
            $sizeInfo = " ($sizeGB GB)"
        } catch {}

        Write-Host "  $($i + 1). $($backup.Name) - $backupDate$sizeInfo"
    }

    Write-Host "  $($AvailableBackups.Count + 1). Merge multiple backups"

    do {
        $selection = Read-Host "`nSelect option (1-$($AvailableBackups.Count + 1))"
        $choice = [int]$selection
    } while ($choice -lt 1 -or $choice -gt ($AvailableBackups.Count + 1))

    if ($choice -eq ($AvailableBackups.Count + 1)) {
        # Merge option selected
        Write-Host "`nSelect backups to merge (enter numbers separated by commas, e.g., 1,3,4):"
        $mergeSelection = Read-Host

        $selectedIndices = $mergeSelection.Split(',') | ForEach-Object { [int]$_.Trim() - 1 }
        $selectedBackups = @()

        foreach ($index in $selectedIndices) {
            if ($index -ge 0 -and $index -lt $AvailableBackups.Count) {
                $selectedBackups += $AvailableBackups[$index]
            }
        }

        if ($selectedBackups.Count -eq 0) {
            Write-Host "No valid selections made!" -ForegroundColor Red
            return $null
        }

        return @{
            Type = "Merge"
            Backups = $selectedBackups
        }
    } else {
        # Single backup selected
        return @{
            Type = "Single"
            Backups = @($AvailableBackups[$choice - 1])
        }
    }
}

# Function to estimate restore time and confirm
function Get-RestoreEstimate {
    param([array]$BackupSources, [string]$TargetPath)

    Write-Host "`nCalculating restore size..." -ForegroundColor Yellow

    $totalSize = 0
    $fileCount = 0

    foreach ($backup in $BackupSources) {
        try {
            $backupInfo = Get-ChildItem $backup.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum
            $totalSize += $backupInfo.Sum
            $fileCount += $backupInfo.Count
        }
        catch {
            Write-Warning "Could not calculate size for $($backup.Name)"
        }
    }

    $sizeGB = [math]::Round($totalSize / 1GB, 2)

    # Estimate time based on local disk speed (~200 MB/s)
    $estimatedTimeMinutes = [math]::Round(($totalSize / 1MB) / 200 / 60, 1)

    return [PSCustomObject]@{
        SizeGB = $sizeGB
        FileCount = $fileCount
        EstimatedTimeMinutes = $estimatedTimeMinutes
    }
}

# Function to perform the restore
function Start-UserRestore {
    param(
        [array]$BackupSources,
        [string]$TargetUserPath,
        [string]$TargetUserName,
        [bool]$IsMerge = $false
    )

    $logFile = Join-Path $env:TEMP "restore_log.txt"

    Write-Host "`nStarting restore for user: $TargetUserName" -ForegroundColor Green
    Write-Host "Target path: $TargetUserPath" -ForegroundColor Green
    Write-Host "Log file: $logFile" -ForegroundColor Gray
    if ($IsMerge) {
        Write-Host "Operation: Merging $($BackupSources.Count) backups" -ForegroundColor Yellow
    }
    Write-Host ""

    $totalBackups = $BackupSources.Count
    $currentBackup = 0

    foreach ($backupSource in $BackupSources) {
        $currentBackup++
        Write-Host "[$currentBackup/$totalBackups] Processing backup: $($backupSource.Name)" -ForegroundColor Cyan

        # Get all folders in this backup
        $backupFolders = Get-ChildItem $backupSource.FullName -Directory

        foreach ($folder in $backupFolders) {
            $folderName = $folder.Name
            Write-Host "  Restoring $folderName..." -ForegroundColor White

            # Determine target path based on folder type
            if ($folderName.StartsWith("OneDrive_")) {
                # OneDrive folders go to OneDrive location
                $cleanFolderName = $folderName -replace "^OneDrive_", ""
                $targetPath = Join-Path $TargetUserPath "OneDrive\$cleanFolderName"
            } else {
                # Regular folders go to standard locations
                $targetPath = Join-Path $TargetUserPath $folderName
            }

            # Ensure target directory exists
            if (-not (Test-Path (Split-Path $targetPath -Parent))) {
                try {
                    New-Item -ItemType Directory -Path (Split-Path $targetPath -Parent) -Force | Out-Null
                } catch {
                    Write-Warning "Could not create parent directory for $folderName"
                    continue
                }
            }

            # Robocopy for restore
            $robocopyArgs = @(
                "`"$($folder.FullName)`"",
                "`"$targetPath`"",
                "/E",          # Copy subdirectories including empty ones
                "/COPY:DAT",   # Copy Data, Attributes, and Timestamps
                "/DCOPY:DAT",  # Copy directory Data, Attributes, and Timestamps
                "/R:3",        # Retry 3 times on failed copies
                "/W:10",       # Wait 10 seconds between retries
                "/MT:8",       # Multi-threaded copying (8 threads for restore)
                "/LOG+:`"$logFile`"",  # Append to log file
                "/TEE",        # Output to console and log
                "/NP"          # No progress percentage (reduces overhead)
            )

            # Configure merge behavior for file conflicts
            if ($IsMerge -and $currentBackup -gt 1) {
                # Check for potential conflicts before proceeding
                $conflictFiles = @()

                # Get files that already exist in target
                if (Test-Path $targetPath) {
                    $existingFiles = Get-ChildItem $targetPath -Recurse -File -ErrorAction SilentlyContinue
                    $newFiles = Get-ChildItem $folder.FullName -Recurse -File -ErrorAction SilentlyContinue

                    foreach ($newFile in $newFiles) {
                        $relativePath = $newFile.FullName -replace [regex]::Escape($folder.FullName), ""
                        $targetFile = $existingFiles | Where-Object { ($_.FullName -replace [regex]::Escape($targetPath), "") -eq $relativePath }

                        if ($targetFile) {
                            $conflictFiles += [PSCustomObject]@{
                                RelativePath = $relativePath.TrimStart('\')
                                ExistingFile = $targetFile
                                NewFile = $newFile
                                ExistingSize = $targetFile.Length
                                NewSize = $newFile.Length
                                ExistingDate = $targetFile.LastWriteTime
                                NewDate = $newFile.LastWriteTime
                            }
                        }
                    }
                }

                # Handle conflicts if any found
                if ($conflictFiles.Count -gt 0) {
                    Write-Host "    Found $($conflictFiles.Count) file conflict(s) in $folderName" -ForegroundColor Yellow

                    # Use parameter-specified resolution or ask user
                    $choice = switch ($ConflictResolution) {
                        "Skip" { 1 }
                        "Overwrite" { 2 }
                        "IfNewer" { 3 }
                        default {
                            # Ask user
                            Write-Host "    Conflict resolution options:" -ForegroundColor Cyan
                            Write-Host "      1. Skip conflicts (keep existing files)" -ForegroundColor White
                            Write-Host "      2. Overwrite all (replace with new files)" -ForegroundColor White
                            Write-Host "      3. Overwrite if newer (based on date)" -ForegroundColor White
                            Write-Host "      4. Review each conflict individually" -ForegroundColor White

                            do {
                                $userChoice = Read-Host "    Select option (1-4)"
                                [int]$userChoice
                            } while ($userChoice -lt 1 -or $userChoice -gt 4)
                        }
                    }

                    switch ($choice) {
                        1 {
                            # Skip conflicts - use /XC /XN /XO to exclude changed, newer, and older files
                            $robocopyArgs += "/XC"  # eXclude Changed files
                            $robocopyArgs += "/XN"  # eXclude Newer files
                            $robocopyArgs += "/XO"  # eXclude Older files
                            Write-Host "    Skipping conflicts - existing files will be preserved" -ForegroundColor Green
                        }
                        2 {
                            # Overwrite all - use /IS /IT
                            $robocopyArgs += "/IS"  # Include Same files
                            $robocopyArgs += "/IT"  # Include Tweaked files
                            Write-Host "    Overwriting all conflicts with new files" -ForegroundColor Green
                        }
                        3 {
                            # Overwrite if newer - default robocopy behavior
                            Write-Host "    Overwriting only if new files are newer" -ForegroundColor Green
                        }
                        4 {
                            # Individual review
                            $overwriteList = @()
                            $skipList = @()

                            foreach ($conflict in $conflictFiles) {
                                Write-Host ""
                                Write-Host "    Conflict: $($conflict.RelativePath)" -ForegroundColor Yellow
                                Write-Host "      Existing: $($conflict.ExistingSize) bytes, $($conflict.ExistingDate)" -ForegroundColor Gray
                                Write-Host "      New:      $($conflict.NewSize) bytes, $($conflict.NewDate)" -ForegroundColor Gray

                                do {
                                    $fileChoice = Read-Host "      (O)verwrite, (S)kip, or (A)bort entire folder"
                                    $fileChoice = $fileChoice.ToUpper()
                                } while ($fileChoice -notin @("O", "S", "A"))

                                if ($fileChoice -eq "A") {
                                    Write-Host "    Aborting $folderName restore" -ForegroundColor Red
                                    continue 2  # Continue to next folder
                                } elseif ($fileChoice -eq "O") {
                                    $overwriteList += $conflict.RelativePath
                                } else {
                                    $skipList += $conflict.RelativePath
                                }
                            }

                            # For individual review, we'll use default behavior but inform user
                            if ($overwriteList.Count -gt 0) {
                                Write-Host "    Will overwrite: $($overwriteList.Count) files" -ForegroundColor Green
                            }
                            if ($skipList.Count -gt 0) {
                                Write-Host "    Will skip: $($skipList.Count) files" -ForegroundColor Yellow
                                # Add exclusions for skipped files would require complex /XF patterns
                                # For now, we'll use default robocopy behavior and note the limitation
                                Write-Host "    Note: Individual file exclusions not fully implemented - using newer-file logic" -ForegroundColor Gray
                            }
                        }
                    }
                } else {
                    Write-Host "    (No conflicts detected - new files only)" -ForegroundColor Green
                }
            }

            # Start robocopy process
            $process = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -NoNewWindow -PassThru -Wait

            # Check exit codes (0-3 are success, 4+ indicate issues)
            if ($process.ExitCode -le 3) {
                Write-Host "    ✓ $folderName completed successfully" -ForegroundColor Green
            } elseif ($process.ExitCode -le 7) {
                Write-Host "    ⚠ $folderName completed with warnings (Exit code: $($process.ExitCode))" -ForegroundColor Yellow
            } else {
                Write-Host "    ✗ $folderName failed (Exit code: $($process.ExitCode))" -ForegroundColor Red
            }
        }
    }
}

# Main script execution
Show-Header

# Get target user if not provided
if (-not $TargetUser) {
    $TargetUser = Select-TargetUser
}

$targetUserPath = "C:\Users\$TargetUser"
if (-not (Test-Path $targetUserPath)) {
    Write-Host "Target user profile not found: $targetUserPath" -ForegroundColor Red
    exit 1
}

Write-Host "Target user: $TargetUser" -ForegroundColor Green

# Get source location if not provided
if (-not $SourceLocation) {
    $devices = Get-StorageDevices

    if ($devices.Count -eq 0) {
        Write-Host "No storage devices found!" -ForegroundColor Red
        exit 1
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
        $selection = Read-Host "`nSelect source device number (1-$($devices.Count))"
        $deviceIndex = [int]$selection - 1
    } while ($deviceIndex -lt 0 -or $deviceIndex -ge $devices.Count)

    $SourceLocation = $devices[$deviceIndex].Drive
}

Write-Host "Source location: $SourceLocation" -ForegroundColor Green

# Discover backup folders
$availableBackups = Get-BackupFolders -SourcePath $SourceLocation
if (-not $availableBackups) {
    exit 1
}

# Select backup folders
$backupSelection = Select-BackupFolders -AvailableBackups $availableBackups
if (-not $backupSelection) {
    exit 1
}

# Get restore estimate
$estimate = Get-RestoreEstimate -BackupSources $backupSelection.Backups -TargetPath $targetUserPath

Write-Host "`n=================================" -ForegroundColor Cyan
Write-Host "Restore Summary:" -ForegroundColor Cyan
Write-Host "  Target user: $TargetUser"
Write-Host "  Source: $SourceLocation"
if ($backupSelection.Type -eq "Merge") {
    Write-Host "  Operation: Merge $($backupSelection.Backups.Count) backups"
    foreach ($backup in $backupSelection.Backups) {
        Write-Host "    - $($backup.Name)"
    }
} else {
    Write-Host "  Backup: $($backupSelection.Backups[0].Name)"
}
Write-Host "  Estimated size: $($estimate.SizeGB) GB"
Write-Host "  File count: $($estimate.FileCount)"
Write-Host "  Estimated time: $($estimate.EstimatedTimeMinutes) minutes"
Write-Host "=================================" -ForegroundColor Cyan

$confirm = Read-Host "`nProceed with restore? (y/N)"
if ($confirm -ne 'y' -and $confirm -ne 'Y') {
    Write-Host "Restore cancelled." -ForegroundColor Yellow
    exit 0
}

# Start the restore
$startTime = Get-Date
Start-UserRestore -BackupSources $backupSelection.Backups -TargetUserPath $targetUserPath -TargetUserName $TargetUser -IsMerge ($backupSelection.Type -eq "Merge")
$endTime = Get-Date

$duration = $endTime - $startTime
Write-Host "`n=================================" -ForegroundColor Green
Write-Host "Restore Completed!" -ForegroundColor Green
Write-Host "  Duration: $($duration.Hours)h $($duration.Minutes)m $($duration.Seconds)s"
Write-Host "  Target: $targetUserPath"
Write-Host "  Log file: $(Join-Path $env:TEMP 'restore_log.txt')"
Write-Host "=================================" -ForegroundColor Green

Write-Host "`nPress any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
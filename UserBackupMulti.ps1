# UserBackupMulti.ps1 - Multi-Device/Multi-User Backup Script with Merge
# Execute remotely with: iwr -useb "your-url/UserBackupMulti.ps1" | iex

param(
    [string[]]$Usernames,
    [string]$BackupLocation,
    [string]$BackupFolder,
    [switch]$MultiDevice
)

# Function to display header
function Show-Header {
    Clear-Host
    Write-Host "=================================" -ForegroundColor Cyan
    Write-Host "Multi-Device User Backup Tool" -ForegroundColor Cyan
    Write-Host "=================================" -ForegroundColor Cyan
    Write-Host ""
}

# Function to select users for backup (can select multiple)
function Select-Users {
    Write-Host "Available users:" -ForegroundColor Yellow

    # Try WMI method first
    try {
        $wmiUsers = Get-WmiObject -Class Win32_UserProfile | Where-Object {
            $_.LocalPath -like "C:\Users\*" -and
            $_.LocalPath -notmatch "(Public|Default|All Users)$" -and
            -not $_.Special
        }

        if ($wmiUsers -and $wmiUsers.Count -gt 0) {
            $userDisplayList = @()
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

                $userDisplayList += [PSCustomObject]@{
                    Number = $userNum
                    DisplayName = $displayName
                    FolderName = $userName
                }

                Write-Host "  $userNum. $displayName"
                $userNum++
            }

            Write-Host "  A. All users"
            Write-Host ""
            Write-Host "Enter user numbers separated by commas (e.g., 1,3,5) or 'A' for all:"
            $selection = Read-Host

            if ($selection.ToUpper() -eq "A") {
                return $userDisplayList.FolderName
            } else {
                $selectedNumbers = $selection.Split(',') | ForEach-Object { [int]$_.Trim() }
                $selectedUsers = @()
                foreach ($num in $selectedNumbers) {
                    if ($num -ge 1 -and $num -le $userDisplayList.Count) {
                        $selectedUsers += $userDisplayList[$num - 1].FolderName
                    }
                }
                return $selectedUsers
            }
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

    Write-Host "  A. All users"
    Write-Host ""
    Write-Host "Enter user numbers separated by commas (e.g., 1,3,5) or 'A' for all:"
    $selection = Read-Host

    if ($selection.ToUpper() -eq "A") {
        return $userFolders.Name
    } else {
        $selectedNumbers = $selection.Split(',') | ForEach-Object { [int]$_.Trim() }
        $selectedUsers = @()
        foreach ($num in $selectedNumbers) {
            if ($num -ge 1 -and $num -le $userFolders.Count) {
                $selectedUsers += $userFolders[$num - 1].Name
            }
        }
        return $selectedUsers
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

# Function to select multiple devices for backup
function Select-BackupDevices {
    $devices = Get-StorageDevices

    if ($devices.Count -eq 0) {
        Write-Host "No storage devices found!" -ForegroundColor Red
        return $null
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

    Write-Host ""
    Write-Host "Select backup destination devices:"
    Write-Host "Enter device numbers separated by commas (e.g., 1,3) or just one number for single device:"
    $selection = Read-Host

    $selectedNumbers = $selection.Split(',') | ForEach-Object { [int]$_.Trim() }
    $selectedDevices = @()

    foreach ($num in $selectedNumbers) {
        if ($num -ge 1 -and $num -le $devices.Count) {
            $selectedDevices += $devices[$num - 1]
        }
    }

    return $selectedDevices
}

# Function to estimate copy time and size for multiple users
function Get-MultiCopyEstimate {
    param([array]$UserList)

    Write-Host "Calculating total backup size..." -ForegroundColor Yellow

    $totalSize = 0
    $fileCount = 0

    foreach ($username in $UserList) {
        $userPath = "C:\Users\$username"
        if (-not (Test-Path $userPath)) {
            Write-Warning "User profile not found: $userPath"
            continue
        }

        Write-Host "  Calculating size for user: $username" -ForegroundColor Gray

        $folders = @("Desktop", "Downloads", "Documents", "Pictures", "Videos", "Music")

        # Check OneDrive folders
        $oneDriveFolders = @(
            @{Source = "$userPath\OneDrive\Desktop"; Dest = "OneDrive_Desktop"},
            @{Source = "$userPath\OneDrive\Documents"; Dest = "OneDrive_Documents"},
            @{Source = "$userPath\OneDrive\Pictures"; Dest = "OneDrive_Pictures"},
            @{Source = "$userPath\OneDrive\Videos"; Dest = "OneDrive_Videos"},
            @{Source = "$userPath\OneDrive\Music"; Dest = "OneDrive_Music"}
        )

        # Calculate standard folders
        foreach ($folder in $folders) {
            $folderPath = Join-Path $userPath $folder
            if (Test-Path $folderPath) {
                try {
                    $folderInfo = Get-ChildItem $folderPath -Recurse -File -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum
                    $totalSize += $folderInfo.Sum
                    $fileCount += $folderInfo.Count
                }
                catch {
                    Write-Warning "Could not calculate size for $username\$folder"
                }
            }
        }

        # Calculate OneDrive folders
        foreach ($oneFolder in $oneDriveFolders) {
            if (Test-Path $oneFolder.Source) {
                try {
                    $folderInfo = Get-ChildItem $oneFolder.Source -Recurse -File -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum
                    $totalSize += $folderInfo.Sum
                    $fileCount += $folderInfo.Count
                }
                catch {
                    Write-Warning "Could not calculate size for $username\$($oneFolder.Dest)"
                }
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
        UserCount = $UserList.Count
    }
}

# Function to perform multi-user backup with merge
function Start-MultiUserBackup {
    param(
        [array]$UserList,
        [array]$DestinationDevices,
        [string]$BackupFolderName
    )

    $folders = @("Desktop", "Downloads", "Documents", "Pictures", "Videos", "Music")

    # Process each destination device
    foreach ($device in $DestinationDevices) {
        $deviceBackupPath = Join-Path $device.Drive $BackupFolderName
        $logFile = Join-Path $deviceBackupPath "backup_log.txt"

        Write-Host "`n=================================" -ForegroundColor Green
        Write-Host "Backing up to device: $($device.Drive) ($($device.Label))" -ForegroundColor Green
        Write-Host "Destination: $deviceBackupPath" -ForegroundColor Green
        Write-Host "=================================" -ForegroundColor Green

        # Create backup directory if it doesn't exist
        if (-not (Test-Path $deviceBackupPath)) {
            try {
                New-Item -ItemType Directory -Path $deviceBackupPath -Force | Out-Null
                Write-Host "Created backup directory: $deviceBackupPath" -ForegroundColor Green
            }
            catch {
                Write-Host "Failed to create backup directory: $($_.Exception.Message)" -ForegroundColor Red
                continue
            }
        }

        $totalUsers = $UserList.Count
        $currentUser = 0

        foreach ($username in $UserList) {
            $currentUser++
            $userPath = "C:\Users\$username"

            if (-not (Test-Path $userPath)) {
                Write-Host "[$currentUser/$totalUsers] Skipping user $username (profile not found)" -ForegroundColor Red
                continue
            }

            Write-Host "[$currentUser/$totalUsers] Processing user: $username" -ForegroundColor Cyan

            # OneDrive folders that may contain the actual user data
            $oneDriveFolders = @(
                @{Source = "$userPath\OneDrive\Desktop"; Dest = "OneDrive_Desktop"},
                @{Source = "$userPath\OneDrive\Documents"; Dest = "OneDrive_Documents"},
                @{Source = "$userPath\OneDrive\Pictures"; Dest = "OneDrive_Pictures"},
                @{Source = "$userPath\OneDrive\Videos"; Dest = "OneDrive_Videos"},
                @{Source = "$userPath\OneDrive\Music"; Dest = "OneDrive_Music"}
            )

            # Backup standard folders
            foreach ($folder in $folders) {
                $sourcePath = Join-Path $userPath $folder

                # Create merged destination path (include username to avoid conflicts)
                $mergedFolderName = if ($UserList.Count -gt 1) { "${folder}_${username}" } else { $folder }
                $destPath = Join-Path $deviceBackupPath $mergedFolderName

                if (Test-Path $sourcePath) {
                    Write-Host "  Backing up $folder..." -ForegroundColor White

                    # Robocopy with complete mirroring and full file copy
                    $robocopyArgs = @(
                        "`"$sourcePath`"",
                        "`"$destPath`"",
                        "/MIR",        # Mirror directory (copies everything, creates dirs, deletes extras)
                        "/COPY:DAT",   # Copy Data, Attributes, and Timestamps
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
                        Write-Host "    ✓ $folder completed successfully" -ForegroundColor Green
                    } elseif ($process.ExitCode -le 7) {
                        Write-Host "    ⚠ $folder completed with warnings (Exit code: $($process.ExitCode))" -ForegroundColor Yellow
                    } else {
                        Write-Host "    ✗ $folder failed (Exit code: $($process.ExitCode))" -ForegroundColor Red
                    }
                } else {
                    Write-Host "  Skipping $folder (not found)" -ForegroundColor Gray
                }
            }

            # Backup OneDrive folders
            foreach ($oneFolder in $oneDriveFolders) {
                if (Test-Path $oneFolder.Source) {
                    Write-Host "  Backing up $($oneFolder.Dest)..." -ForegroundColor White

                    # Create merged destination path (include username to avoid conflicts)
                    $mergedFolderName = if ($UserList.Count -gt 1) { "$($oneFolder.Dest)_${username}" } else { $oneFolder.Dest }
                    $destPath = Join-Path $deviceBackupPath $mergedFolderName

                    # Robocopy with complete mirroring and full file copy
                    $robocopyArgs = @(
                        "`"$($oneFolder.Source)`"",
                        "`"$destPath`"",
                        "/MIR",        # Mirror directory (copies everything, creates dirs, deletes extras)
                        "/COPY:DAT",   # Copy Data, Attributes, and Timestamps
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
                        Write-Host "    ✓ $($oneFolder.Dest) completed successfully" -ForegroundColor Green
                    } elseif ($process.ExitCode -le 7) {
                        Write-Host "    ⚠ $($oneFolder.Dest) completed with warnings (Exit code: $($process.ExitCode))" -ForegroundColor Yellow
                    } else {
                        Write-Host "    ✗ $($oneFolder.Dest) failed (Exit code: $($process.ExitCode))" -ForegroundColor Red
                    }
                } else {
                    Write-Host "  Skipping $($oneFolder.Dest) (not found)" -ForegroundColor Gray
                }
            }
        }

        Write-Host "`nCompleted backup to $($device.Drive)" -ForegroundColor Green
    }
}

# Main script execution
Show-Header

# Get usernames if not provided
if (-not $Usernames -or $Usernames.Count -eq 0) {
    $Usernames = Select-Users
}

if (-not $Usernames -or $Usernames.Count -eq 0) {
    Write-Host "No users selected!" -ForegroundColor Red
    exit 1
}

Write-Host "Selected users: $($Usernames -join ', ')" -ForegroundColor Green

# Get backup destinations
if (-not $BackupLocation) {
    $selectedDevices = Select-BackupDevices
    if (-not $selectedDevices -or $selectedDevices.Count -eq 0) {
        Write-Host "No backup devices selected!" -ForegroundColor Red
        exit 1
    }
} else {
    # Single device specified via parameter
    $selectedDevices = @([PSCustomObject]@{
        Drive = $BackupLocation
        Label = "Specified Device"
        Size = "Unknown"
        Free = "Unknown"
        Type = "Parameter"
    })
}

Write-Host "Selected backup devices: $($selectedDevices.Drive -join ', ')" -ForegroundColor Green

# Get backup folder if not provided
if (-not $BackupFolder) {
    $defaultName = "MultiBackup_$(Get-Date -Format 'yyyy-MM-dd_HH-mm')"
    $BackupFolder = Read-Host "`nEnter backup folder name (default: $defaultName)"
    if (-not $BackupFolder) {
        $BackupFolder = $defaultName
    }
}

Write-Host "Backup folder: $BackupFolder" -ForegroundColor Green

# Validate all destination devices are accessible
foreach ($device in $selectedDevices) {
    if (-not (Test-Path $device.Drive)) {
        Write-Host "Device $($device.Drive) is not accessible!" -ForegroundColor Red
        exit 1
    }
}

# Get backup estimate
$estimate = Get-MultiCopyEstimate -UserList $Usernames

Write-Host "`n=================================" -ForegroundColor Cyan
Write-Host "Multi-User Backup Summary:" -ForegroundColor Cyan
Write-Host "  Users: $($Usernames -join ', ')"
Write-Host "  User count: $($estimate.UserCount)"
Write-Host "  Destinations: $($selectedDevices.Drive -join ', ')"
Write-Host "  Backup folder: $BackupFolder"
Write-Host "  Estimated total size: $($estimate.SizeGB) GB"
Write-Host "  Total file count: $($estimate.FileCount)"
Write-Host "  Estimated time (USB 3.0): $($estimate.EstimatedTimeUSB3) minutes"
Write-Host "  Estimated time (USB 2.0): $($estimate.EstimatedTimeUSB2) minutes"
if ($Usernames.Count -gt 1) {
    Write-Host "  Merge behavior: Folders will be named with username suffix" -ForegroundColor Yellow
}
if ($selectedDevices.Count -gt 1) {
    Write-Host "  Multi-device: Backup will be copied to $($selectedDevices.Count) devices" -ForegroundColor Yellow
}
Write-Host "=================================" -ForegroundColor Cyan

$confirm = Read-Host "`nProceed with multi-user backup? (y/N)"
if ($confirm -ne 'y' -and $confirm -ne 'Y') {
    Write-Host "Backup cancelled." -ForegroundColor Yellow
    exit 0
}

# Start the backup
$startTime = Get-Date
Start-MultiUserBackup -UserList $Usernames -DestinationDevices $selectedDevices -BackupFolderName $BackupFolder
$endTime = Get-Date

$duration = $endTime - $startTime
Write-Host "`n=================================" -ForegroundColor Green
Write-Host "Multi-User Backup Completed!" -ForegroundColor Green
Write-Host "  Duration: $($duration.Hours)h $($duration.Minutes)m $($duration.Seconds)s"
Write-Host "  Users backed up: $($Usernames.Count)"
Write-Host "  Devices written to: $($selectedDevices.Count)"
foreach ($device in $selectedDevices) {
    $backupPath = Join-Path $device.Drive $BackupFolder
    Write-Host "    $backupPath"
}
Write-Host "=================================" -ForegroundColor Green

Write-Host "`nPress any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
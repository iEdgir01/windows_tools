# UserBackupDebug.ps1 - Fast User Data Backup Script with Debug Output
# Execute remotely with: iwr -useb "your-url/UserBackupDebug.ps1" | iex

param(
    [string]$Username,
    [string]$BackupLocation,
    [string]$BackupFolder
)

# Debug is always enabled in this version
$Debug = $true

# Function to open debug console
function Start-DebugConsole {
    $debugScript = @'
$Host.UI.RawUI.WindowTitle = "Backup Script Debug Output"
Write-Host "=== DEBUG CONSOLE ===" -ForegroundColor Green
Write-Host "Monitoring backup script execution..." -ForegroundColor Yellow
Write-Host "Log file: $env:TEMP\backup_debug.log" -ForegroundColor Gray
Write-Host ""

$lastSize = 0
while ($true) {
    if (Test-Path "$env:TEMP\backup_debug.log") {
        $currentSize = (Get-Item "$env:TEMP\backup_debug.log").Length
        if ($currentSize -gt $lastSize) {
            $content = Get-Content "$env:TEMP\backup_debug.log" -Tail 50
            Clear-Host
            Write-Host "=== DEBUG CONSOLE ===" -ForegroundColor Green
            Write-Host "Log file: $env:TEMP\backup_debug.log" -ForegroundColor Gray
            Write-Host ""
            $content | ForEach-Object { Write-Host $_ -ForegroundColor White }
            $lastSize = $currentSize
        }
    }
    Start-Sleep -Milliseconds 500
}
'@

    Start-Process powershell -ArgumentList "-NoExit", "-Command", $debugScript
    Start-Sleep -Seconds 2
}

# Function to write debug output
function Write-Debug {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    try {
        Add-Content -Path "$env:TEMP\backup_debug.log" -Value "[$timestamp] $Message" -ErrorAction SilentlyContinue
    } catch {}
}

# Function to display header
function Show-Header {
    Clear-Host
    Write-Host "=================================" -ForegroundColor Cyan
    Write-Host "   Windows User Backup Tool" -ForegroundColor Cyan
    Write-Host "      (DEBUG MODE ENABLED)" -ForegroundColor Red
    Write-Host "=================================" -ForegroundColor Cyan
    Write-Host ""
}

# Function to get available users
function Get-AvailableUsers {
    Write-Debug "Starting Get-AvailableUsers function"

    # Method 1: Try WMI to get user profiles (more reliable for display names)
    Write-Debug "Method 1: WMI Win32_UserProfile approach"
    try {
        $wmiUsers = Get-WmiObject -Class Win32_UserProfile | Where-Object {
            $_.LocalPath -like "C:\Users\*" -and
            $_.LocalPath -notmatch "(Public|Default|All Users)$" -and
            -not $_.Special
        }

        Write-Debug "Found $($wmiUsers.Count) WMI user profiles"

        if ($wmiUsers) {
            $users = @()
            foreach ($profile in $wmiUsers) {
                $userName = Split-Path $profile.LocalPath -Leaf
                Write-Debug "  WMI Profile: LocalPath='$($profile.LocalPath)' | SID='$($profile.SID)' | FolderName='$userName'"

                # Get the SID and try to resolve to a friendly name
                try {
                    $sid = New-Object System.Security.Principal.SecurityIdentifier($profile.SID)
                    $ntAccount = $sid.Translate([System.Security.Principal.NTAccount])
                    $friendlyName = $ntAccount.Value.Split('\')[-1]
                    Write-Debug "    SID resolved to: '$($ntAccount.Value)' | FriendlyName: '$friendlyName'"
                    if ($friendlyName -and $friendlyName -ne $userName) {
                        Write-Debug "    Using friendly name '$friendlyName' instead of folder name '$userName'"
                        $userName = $friendlyName
                    }
                } catch {
                    Write-Debug "    SID translation failed: $($_.Exception.Message)"
                }
                $users += $userName
                Write-Debug "    Final username added: '$userName'"
            }
            if ($users.Count -gt 0) {
                Write-Debug "WMI method successful, returning $($users.Count) users"
                return $users
            }
        }
    } catch {
        Write-Debug "WMI method failed: $($_.Exception.Message)"
    }

    # Method 2: Fallback to directory listing
    Write-Debug "Method 2: Fallback to directory listing"
    $userFolders = Get-ChildItem "C:\Users" -Directory | Where-Object {
        $_.Name -notin @("Public", "Default", "Default User", "All Users")
    }

    Write-Debug "Found $($userFolders.Count) user folders via directory listing"
    $users = @()
    foreach ($folder in $userFolders) {
        $folderName = $folder.Name
        Write-Debug "  Processing folder: '$folderName' (Length: $($folderName.Length))"
        $users += $folderName
    }

    Write-Debug "Directory method returning $($users.Count) users"
    return $users
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
        [string]$UserName
    )

    $folders = @("Desktop", "Downloads", "Documents", "Pictures", "Videos", "Music")
    $logFile = Join-Path $DestinationPath "backup_log.txt"

    Write-Host "`nStarting backup for user: $UserName" -ForegroundColor Green
    Write-Host "Destination: $DestinationPath" -ForegroundColor Green
    Write-Host "Log file: $logFile" -ForegroundColor Gray
    Write-Host ""

    $totalFolders = $folders.Count
    $currentFolder = 0

    foreach ($folder in $folders) {
        $currentFolder++
        $sourcePath = Join-Path $UserPath $folder
        $destPath = Join-Path $DestinationPath $folder

        if (Test-Path $sourcePath) {
            Write-Host "[$currentFolder/$totalFolders] Copying $folder..." -ForegroundColor Cyan

            # Robocopy with optimal settings for speed and recovery
            $robocopyArgs = @(
                "`"$sourcePath`"",
                "`"$destPath`"",
                "/E",          # Copy subdirectories including empty ones
                "/COPY:DAT",   # Copy Data, Attributes, and Timestamps
                "/DCOPY:DAT",  # Copy directory Data, Attributes, and Timestamps
                "/R:3",        # Retry 3 times on failed copies
                "/W:10",       # Wait 10 seconds between retries
                "/MT:16",      # Multi-threaded copying (16 threads for speed)
                "/LOG+:`"$logFile`"",  # Append to log file
                "/TEE",        # Output to console and log
                "/NP",         # No progress percentage (reduces overhead)
                "/NDL",        # No directory list
                "/NFL"         # No file list (for speed)
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
}

# Main script execution
Start-DebugConsole
Remove-Item "$env:TEMP\backup_debug.log" -ErrorAction SilentlyContinue
Write-Debug "=== BACKUP SCRIPT STARTED WITH DEBUG ==="
Show-Header

# Get username if not provided
if (-not $Username) {
    $users = Get-AvailableUsers

    if ($users.Count -eq 0) {
        Write-Host "No user profiles found!" -ForegroundColor Red
        exit 1
    }

    Write-Debug "About to display users. Array count: $($users.Count)"

    # Test different ways to extract and display the username
    for ($i = 0; $i -lt $users.Count; $i++) {
        $userNum = $i + 1

        # Test 1: Direct array access
        $test1 = $users[$i]
        Write-Debug "Test1 - Direct access users[$i]: '$test1' (Length: $($test1.Length))"

        # Test 2: ToString() method
        $test2 = $users[$i].ToString()
        Write-Debug "Test2 - ToString() users[$i]: '$test2' (Length: $($test2.Length))"

        # Test 3: String casting
        $test3 = [string]$users[$i]
        Write-Debug "Test3 - String cast users[$i]: '$test3' (Length: $($test3.Length))"

        # Test 4: Variable assignment then access
        $temp = $users[$i]
        $test4 = "$temp"
        Write-Debug "Test4 - Variable then string users[$i]: '$test4' (Length: $($test4.Length))"

        # Test 5: Format operator
        $test5 = "{0}" -f $users[$i]
        Write-Debug "Test5 - Format operator users[$i]: '$test5' (Length: $($test5.Length))"

        # Test 6: Out-String
        $test6 = ($users[$i] | Out-String).Trim()
        Write-Debug "Test6 - Out-String users[$i]: '$test6' (Length: $($test6.Length))"

        Write-Debug "Array element type: $($users[$i].GetType().FullName)"
        Write-Debug "Array element chars: $(($users[$i].ToCharArray() | ForEach-Object { '[{0}]' -f $_ }) -join '')"
    }

    Write-Host "Available users:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $users.Count; $i++) {
        $userNum = $i + 1

        # Use char array reconstruction to bypass string corruption
        $userChars = $users[$i].ToCharArray()
        $userName = -join $userChars
        Write-Debug "Final display attempt using char array - user[$i]: '$userName' as number $userNum"

        Write-Host "  $userNum. $userName"
    }

    do {
        $selection = Read-Host "`nSelect user number (1-$($users.Count))"
        $userIndex = [int]$selection - 1
    } while ($userIndex -lt 0 -or $userIndex -ge $users.Count)

    $Username = $users[$userIndex]
}

$userProfilePath = "C:\Users\$Username"
if (-not (Test-Path $userProfilePath)) {
    Write-Host "User profile not found: $userProfilePath" -ForegroundColor Red
    exit 1
}

Write-Host "Selected user: $Username" -ForegroundColor Green

# Get backup location if not provided
if (-not $BackupLocation) {
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
        $selection = Read-Host "`nSelect storage device number (1-$($devices.Count))"
        $deviceIndex = [int]$selection - 1
    } while ($deviceIndex -lt 0 -or $deviceIndex -ge $devices.Count)

    $BackupLocation = $devices[$deviceIndex].Drive
}

Write-Host "Selected backup location: $BackupLocation" -ForegroundColor Green

# Get backup folder if not provided
if (-not $BackupFolder) {
    $BackupFolder = Read-Host "`nEnter backup folder name (will be created in $BackupLocation)"
}

$fullBackupPath = Join-Path $BackupLocation $BackupFolder
Write-Host "Full backup path: $fullBackupPath" -ForegroundColor Green

# Create backup directory if it doesn't exist
if (-not (Test-Path $fullBackupPath)) {
    try {
        New-Item -ItemType Directory -Path $fullBackupPath -Force | Out-Null
        Write-Host "Created backup directory: $fullBackupPath" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to create backup directory: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# Get copy estimate
$estimate = Get-CopyEstimate -SourcePath $userProfilePath

Write-Host "`n=================================" -ForegroundColor Cyan
Write-Host "Backup Summary:" -ForegroundColor Cyan
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
    exit 0
}

# Start the backup
$startTime = Get-Date
Start-UserBackup -UserPath $userProfilePath -DestinationPath $fullBackupPath -UserName $Username
$endTime = Get-Date

$duration = $endTime - $startTime
Write-Host "`n=================================" -ForegroundColor Green
Write-Host "Backup Completed!" -ForegroundColor Green
Write-Host "  Duration: $($duration.Hours)h $($duration.Minutes)m $($duration.Seconds)s"
Write-Host "  Location: $fullBackupPath"
Write-Host "  Log file: $(Join-Path $fullBackupPath 'backup_log.txt')"
Write-Host "=================================" -ForegroundColor Green

Write-Host "`nPress any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
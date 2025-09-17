# UserBackup.ps1 - Advanced User Data Backup Script with Exact Resume Support
# Execute remotely with: iwr -useb "your-url/UserBackup.ps1" | iex

param(
    [string]$Username,
    [string]$BackupLocation,
    [string]$BackupFolder
)

# --- Global Config ---
$global:LogRoot = "C:\BackupLogs"
if (-not (Test-Path $LogRoot)) { New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null }
$global:SessionLog = Join-Path $LogRoot ("Backup-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")

# Function to display header
function Show-Header {
    Clear-Host
    Write-Host "=================================" -ForegroundColor Cyan
    Write-Host "   Windows User Backup Tool" -ForegroundColor Cyan
    Write-Host "   Enhanced with Exact Resume" -ForegroundColor Cyan
    Write-Host "=================================" -ForegroundColor Cyan
    Write-Host ""
}

# --- Utility Functions ---
function Handle-Error {
    param([string]$Message, [bool]$Critical = $false)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Add-Content $global:SessionLog "[$(Get-Date)] ERROR: $Message"
    if ($Critical) {
        Write-Host "This is a critical error that prevents the script from continuing." -ForegroundColor Red
        Write-Host "Please check the error message above and try again." -ForegroundColor Yellow
        Write-Host "`nPress any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    } else {
        Write-Host "The script will attempt to continue..." -ForegroundColor Yellow
    }
}

function Write-Log {
    param([string]$Message)
    $entry = "[$(Get-Date)] $Message"
    Write-Host $Message -ForegroundColor Gray
    Add-Content $global:SessionLog $entry
}

# Function to display progress bar
function Show-ProgressBar {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Activity,
        [datetime]$StartTime = (Get-Date),
        [int]$Width = 50
    )

    if ($Total -eq 0) { $Total = 1 }
    $percentage = [math]::Round(($Current / $Total) * 100, 1)
    $completed = [math]::Round(($Current / $Total) * $Width)
    $remaining = $Width - $completed

    # Calculate time estimates
    $elapsed = (Get-Date) - $StartTime
    if ($Current -gt 0) {
        $avgTimePerItem = $elapsed.TotalSeconds / $Current
        $remainingItems = $Total - $Current
        $estimatedRemaining = [timespan]::FromSeconds($avgTimePerItem * $remainingItems)
        $remainingText = if ($estimatedRemaining.TotalHours -ge 1) {
            "{0:h\h\ m\m}" -f $estimatedRemaining
        } else {
            "{0:m\m\ s\s}" -f $estimatedRemaining
        }
    } else {
        $remainingText = "Calculating..."
    }

    # Save cursor position and move to top
    $currentPos = $Host.UI.RawUI.CursorPosition
    $Host.UI.RawUI.CursorPosition = @{X=0; Y=0}

    # Create progress bar
    $progressBar = "[${"#" * $completed}${"." * $remaining}]"
    $statusLine = "$Activity - $percentage% ($Current/$Total) - ETA: $remainingText"

    # Display with padding to clear previous text
    $maxWidth = [math]::Max($progressBar.Length, $statusLine.Length) + 10
    Write-Host $progressBar.PadRight($maxWidth) -ForegroundColor Green
    Write-Host $statusLine.PadRight($maxWidth) -ForegroundColor Cyan
    Write-Host "".PadRight($maxWidth) -ForegroundColor Black

    # Restore cursor position
    $Host.UI.RawUI.CursorPosition = $currentPos
}

# Function to save progress to log
function Save-ProgressToLog {
    param(
        [string]$LogPath,
        [int]$CurrentFolder,
        [int]$TotalFolders,
        [int]$CurrentFile,
        [int]$TotalFiles,
        [string]$CurrentFolderName
    )

    $progressData = @{
        Timestamp = Get-Date
        CurrentFolder = $CurrentFolder
        TotalFolders = $TotalFolders
        CurrentFile = $CurrentFile
        TotalFiles = $TotalFiles
        CurrentFolderName = $CurrentFolderName
        PercentComplete = [math]::Round(($CurrentFolder / $TotalFolders) * 100, 1)
    }

    $progressJson = $progressData | ConvertTo-Json -Compress
    Add-Content $LogPath "`nPROGRESS_MARKER: $progressJson"
}

# Function to load progress from log
function Get-ProgressFromLog {
    param([string]$LogPath)

    if (-not (Test-Path $LogPath)) {
        return $null
    }

    try {
        $logContent = Get-Content $LogPath
        $lastProgressLine = $logContent | Where-Object { $_ -match "^PROGRESS_MARKER: " } | Select-Object -Last 1

        if ($lastProgressLine) {
            $progressJson = $lastProgressLine -replace "^PROGRESS_MARKER: ", ""
            $progress = $progressJson | ConvertFrom-Json
            return $progress
        }

        return $null
    }
    catch {
        Write-Log "Warning: Could not parse progress from log: $($_.Exception.Message)"
        return $null
    }
}

# Function to calculate total files for progress tracking
function Get-TotalFileCount {
    param(
        [string]$UserPath,
        [array]$FoldersToProcess,
        [array]$OneDriveFoldersToProcess
    )

    $totalFiles = 0
    Write-Host "Calculating total files for progress tracking..." -ForegroundColor Gray

    foreach ($folder in $FoldersToProcess) {
        $folderPath = Join-Path $UserPath $folder
        if (Test-Path $folderPath) {
            try {
                $fileCount = (Get-ChildItem $folderPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne ".pst" }).Count
                $totalFiles += $fileCount
            } catch {
                # Skip folders with access issues
            }
        }
    }

    foreach ($oneFolder in $OneDriveFoldersToProcess) {
        if (Test-Path $oneFolder.Source) {
            try {
                $fileCount = (Get-ChildItem $oneFolder.Source -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne ".pst" }).Count
                $totalFiles += $fileCount
            } catch {
                # Skip folders with access issues
            }
        }
    }

    return $totalFiles
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
                $selection = [int]$selection
            } while ($selection -lt 1 -or $selection -gt $wmiUsers.Count)

            $selectedProfile = $wmiUsers[$selection - 1]
            return Split-Path $selectedProfile.LocalPath -Leaf
        }
    } catch {
        Write-Host "WMI method failed, trying directory listing..." -ForegroundColor Yellow
    }

    # Fallback: directory listing method
    try {
        $userFolders = Get-ChildItem "C:\Users" -Directory | Where-Object {
            $_.Name -notmatch "(Public|Default|All Users)$"
        }

        if ($userFolders.Count -eq 0) {
            throw "No user folders found"
        }

        $userNum = 1
        foreach ($folder in $userFolders) {
            Write-Host "  $userNum. $($folder.Name)"
            $userNum++
        }

        do {
            $selection = Read-Host "`nSelect user number (1-$($userFolders.Count))"
            $selection = [int]$selection
        } while ($selection -lt 1 -or $selection -gt $userFolders.Count)

        return $userFolders[$selection - 1].Name
    } catch {
        throw "Failed to get user list: $($_.Exception.Message)"
    }
}

# Function to get existing backups on a device
function Get-ExistingBackups {
    param([string]$DevicePath)

    try {
        $backupFolders = Get-ChildItem $DevicePath -Directory | Where-Object {
            $_.Name -match ".*[Bb]ackup.*" -or
            $_.Name -match "\d{8}-\d{6}" -or
            (Test-Path (Join-Path $_.FullName "backup_log.txt"))
        }
        return $backupFolders
    } catch {
        return @()
    }
}

# Function to parse robocopy log for copied files by folder
function Get-CopiedFilesByFolder {
    param([string]$LogPath)

    $copiedFiles = @{}

    if (-not (Test-Path $LogPath)) {
        return $copiedFiles
    }

    try {
        Write-Log "Parsing backup log for exact file resume..."
        $logContent = Get-Content $LogPath -ErrorAction Stop
        $currentFolder = ""

        foreach ($line in $logContent) {
            # Track current source folder
            if ($line -match "^\s*Source\s*:\s*(.+)$") {
                $sourcePath = $matches[1].Trim()
                if ($sourcePath -match "\\([^\\]+)$") {
                    $currentFolder = $matches[1]
                    if (-not $copiedFiles.ContainsKey($currentFolder)) {
                        $copiedFiles[$currentFolder] = @()
                    }
                }
            }
            # Look for successfully copied files
            elseif ($line -match "\s+(New File|same|older|newer|modified)\s+\d+\s+(.+)$") {
                $filePath = $matches[2].Trim()
                if ($currentFolder -and $filePath) {
                    # Extract just the filename relative to the folder
                    $fileName = Split-Path $filePath -Leaf
                    if ($fileName -and $fileName -notin $copiedFiles[$currentFolder]) {
                        $copiedFiles[$currentFolder] += $fileName
                    }
                }
            }
        }

        foreach ($folder in $copiedFiles.Keys) {
            Write-Log "Found $($copiedFiles[$folder].Count) copied files in folder: '$folder'"
        }

        if ($copiedFiles.Keys.Count -eq 0) {
            Write-Log "No folders with copied files found in log"
        }

        return $copiedFiles
    }
    catch {
        Write-Host "Warning: Could not parse log file: $($_.Exception.Message)" -ForegroundColor Yellow
        return @{}
    }
}

# Enhanced storage device detection with multiple fallback methods
function Get-StorageDevices {
    $deviceList = @()
    Write-Host "Detecting storage devices..." -ForegroundColor Gray

    # Method 1: Try CIM first (PowerShell 7+ compatible)
    try {
        $drives = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop | Where-Object {
            $_.DriveType -eq 2 -or $_.DriveType -eq 3
        }

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
    catch {
        Write-Host "CIM method failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Method 2: Try WMI (if available - PowerShell 5.x)
    if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
        try {
            Write-Host "Trying WMI method..." -ForegroundColor Yellow
            $drives = Get-WmiObject -Class Win32_LogicalDisk -ErrorAction Stop | Where-Object {
                $_.DriveType -eq 2 -or $_.DriveType -eq 3
            }

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
        catch {
            Write-Host "WMI method failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Method 3: PowerShell-native fallback (no WMI dependency)
    try {
        Write-Host "Using PowerShell drive detection..." -ForegroundColor Yellow
        $psDrives = Get-PSDrive -PSProvider FileSystem | Where-Object {
            $_.Name -match '^[A-Z]$' -and (Test-Path "$($_.Name):\")
        }

        foreach ($drive in $psDrives) {
            $driveLetter = $drive.Name + ":"
            $sizeGB = "Unknown"
            $freeGB = "Unknown"
            $label = "Drive $driveLetter"
            $type = "Unknown"

            if (Get-Command Get-Volume -ErrorAction SilentlyContinue) {
                try {
                    $volumeInfo = Get-Volume -DriveLetter $drive.Name -ErrorAction SilentlyContinue
                    if ($volumeInfo) {
                        $sizeGB = [math]::Round($volumeInfo.Size / 1GB, 2)
                        $freeGB = [math]::Round($volumeInfo.SizeRemaining / 1GB, 2)
                        $label = if ($volumeInfo.FileSystemLabel) { $volumeInfo.FileSystemLabel } else { "Unlabeled" }
                        $type = "Fixed"
                    }
                }
                catch {
                    # Keep defaults if Get-Volume fails
                }
            }

            $deviceList += [PSCustomObject]@{
                Drive = $driveLetter
                Label = $label
                Size = if ($sizeGB -eq "Unknown") { "Unknown" } else { "$sizeGB GB" }
                Free = if ($freeGB -eq "Unknown") { "Unknown" } else { "$freeGB GB" }
                Type = $type
            }
        }
        return $deviceList
    }
    catch {
        Write-Host "PowerShell drive detection failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Method 4: Last resort - manual drive letter check
    Write-Host "Using basic drive letter detection..." -ForegroundColor Red
    $letters = @("C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z")
    foreach ($letter in $letters) {
        if (Test-Path "$letter`:\") {
            $deviceList += [PSCustomObject]@{
                Drive = "$letter`:"
                Label = "Drive $letter"
                Size = "Unknown"
                Free = "Unknown"
                Type = "Unknown"
            }
        }
    }

    return $deviceList
}

# Function to analyze backup progress with log-based detection
function Compare-BackupProgress {
    param(
        [string]$UserPath,
        [string]$BackupPath
    )

    Write-Host "Analyzing backup progress..." -ForegroundColor Yellow

    # Check for existing log file for exact file tracking
    $logPath = Join-Path $BackupPath "backup_log.txt"
    $copiedFiles = Get-CopiedFilesByFolder -LogPath $logPath

    if ($copiedFiles.Keys.Count -gt 0) {
        Write-Host "Found backup log - using for exact file-level resume analysis" -ForegroundColor Green
    }

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
                # Check if we have copied files info from log
                if ($copiedFiles.ContainsKey($folder)) {
                    $sourceFiles = (Get-ChildItem $sourcePath -Recurse -File -ErrorAction SilentlyContinue)
                    $copiedCount = $copiedFiles[$folder].Count
                    $totalCount = $sourceFiles.Count

                    if ($copiedCount -ge $totalCount) {
                        $complete += @{Type = "Standard"; Name = $folder; Source = $sourcePath; Dest = $destPath; Files = $copiedCount}
                    } else {
                        $incomplete += @{Type = "Standard"; Name = $folder; Source = $sourcePath; Dest = $destPath; SourceFiles = $totalCount; BackupFiles = $copiedCount}
                    }
                } else {
                    # Fallback to file count comparison
                    try {
                        $sourceCount = (Get-ChildItem $sourcePath -Recurse -File -ErrorAction SilentlyContinue).Count
                        $destCount = (Get-ChildItem $destPath -Recurse -File -ErrorAction SilentlyContinue).Count

                        if ($sourceCount -gt $destCount) {
                            $incomplete += @{Type = "Standard"; Name = $folder; Source = $sourcePath; Dest = $destPath; SourceFiles = $sourceCount; BackupFiles = $destCount}
                        } else {
                            $complete += @{Type = "Standard"; Name = $folder; Source = $sourcePath; Dest = $destPath; Files = $destCount}
                        }
                    } catch {
                        $incomplete += @{Type = "Standard"; Name = $folder; Source = $sourcePath; Dest = $destPath; SourceFiles = "Unknown"; BackupFiles = "Unknown"}
                    }
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
                # Check if we have copied files info from log
                if ($copiedFiles.ContainsKey($oneFolder.Dest)) {
                    $sourceFiles = (Get-ChildItem $oneFolder.Source -Recurse -File -ErrorAction SilentlyContinue)
                    $copiedCount = $copiedFiles[$oneFolder.Dest].Count
                    $totalCount = $sourceFiles.Count

                    if ($copiedCount -ge $totalCount) {
                        $complete += @{Type = "OneDrive"; Name = $oneFolder.Dest; Source = $oneFolder.Source; Dest = $destPath; Files = $copiedCount}
                    } else {
                        $incomplete += @{Type = "OneDrive"; Name = $oneFolder.Dest; Source = $oneFolder.Source; Dest = $destPath; SourceFiles = $totalCount; BackupFiles = $copiedCount}
                    }
                } else {
                    # Fallback to file count comparison
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
    }

    return @{
        Missing = $missing
        Incomplete = $incomplete
        Complete = $complete
        CopiedFiles = $copiedFiles
    }
}

# Function to estimate copy time and size
function Get-CopyEstimate {
    param([string]$SourcePath)
    Write-Host "Calculating backup size..." -ForegroundColor Yellow
    $totalSize = 0
    $fileCount = 0

    $folders = @("Desktop", "Downloads", "Documents", "Pictures", "Videos", "Music")
    $oneDriveFolders = @("OneDrive\Desktop", "OneDrive\Documents", "OneDrive\Pictures", "OneDrive\Videos", "OneDrive\Music")

    foreach ($folder in $folders) {
        $folderPath = Join-Path $SourcePath $folder
        if (Test-Path $folderPath) {
            try {
                $files = Get-ChildItem $folderPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne ".pst" }
                $fileCount += $files.Count
                $totalSize += ($files | Measure-Object -Property Length -Sum).Sum
            } catch {
                # Skip folders with access issues
            }
        }
    }

    foreach ($folder in $oneDriveFolders) {
        $folderPath = Join-Path $SourcePath $folder
        if (Test-Path $folderPath) {
            try {
                $files = Get-ChildItem $folderPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne ".pst" }
                $fileCount += $files.Count
                $totalSize += ($files | Measure-Object -Property Length -Sum).Sum
            } catch {
                # Skip folders with access issues
            }
        }
    }

    $sizeGB = [math]::Round($totalSize / 1GB, 2)

    # Estimate transfer times (rough calculations)
    $estimatedTimeUSB3 = [math]::Round($sizeGB / 0.5, 0)  # ~30MB/s for USB 3.0
    $estimatedTimeUSB2 = [math]::Round($sizeGB / 0.08, 0) # ~5MB/s for USB 2.0

    return [PSCustomObject]@{
        SizeGB = $sizeGB
        FileCount = $fileCount
        EstimatedTimeUSB3 = $estimatedTimeUSB3
        EstimatedTimeUSB2 = $estimatedTimeUSB2
    }
}

# Enhanced backup execution with exact file resume
function Start-UserBackup {
    param(
        [string]$UserPath,
        [string]$DestinationPath,
        [string]$UserName,
        [hashtable]$BackupAnalysis = $null
    )

    $folders = @("Desktop", "Downloads", "Documents", "Pictures", "Videos", "Music")
    $logFile = Join-Path $DestinationPath "backup_log.txt"
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

        # Add missing folders
        foreach ($item in $BackupAnalysis.Missing) {
            if ($item.Type -eq "Standard" -and $item.Name -in $folders) {
                $foldersToProcess += $item.Name
            }
        }

        # Add incomplete folders
        foreach ($item in $BackupAnalysis.Incomplete) {
            if ($item.Type -eq "Standard" -and $item.Name -in $folders) {
                $foldersToProcess += $item.Name
            }
        }

        $foldersToProcess = $foldersToProcess | Sort-Object | Get-Unique
    }

    # Determine OneDrive folders to process
    $oneDriveFoldersToProcess = $oneDriveFolders
    if ($BackupAnalysis) {
        $oneDriveFoldersToProcess = @()

        # Add missing OneDrive folders
        foreach ($item in $BackupAnalysis.Missing) {
            if ($item.Type -eq "OneDrive") {
                $matchingFolder = $oneDriveFolders | Where-Object { $_.Dest -eq $item.Name }
                if ($matchingFolder) {
                    $oneDriveFoldersToProcess += $matchingFolder
                }
            }
        }

        # Add incomplete OneDrive folders
        foreach ($item in $BackupAnalysis.Incomplete) {
            if ($item.Type -eq "OneDrive") {
                $matchingFolder = $oneDriveFolders | Where-Object { $_.Dest -eq $item.Name }
                if ($matchingFolder) {
                    $oneDriveFoldersToProcess += $matchingFolder
                }
            }
        }

        $oneDriveFoldersToProcess = $oneDriveFoldersToProcess | Sort-Object -Property Dest -Unique
    }

    # Calculate total files for progress tracking
    $totalFiles = Get-TotalFileCount -UserPath $UserPath -FoldersToProcess $foldersToProcess -OneDriveFoldersToProcess $oneDriveFoldersToProcess

    # Check for saved progress
    $savedProgress = Get-ProgressFromLog -LogPath $logFile
    $startTime = Get-Date
    $currentFileCount = 0

    if ($savedProgress) {
        Write-Host "Resuming from saved progress: $($savedProgress.PercentComplete)% complete" -ForegroundColor Green
        $currentFileCount = $savedProgress.CurrentFile
    }

    # Clear screen and setup progress display
    Clear-Host
    Write-Host "`n`n`n" # Space for progress bar
    Write-Host "Backup Progress for $UserName" -ForegroundColor Cyan
    Write-Host "Destination: $DestinationPath" -ForegroundColor Gray
    Write-Host ""

    $totalFolders = $foldersToProcess.Count + $oneDriveFoldersToProcess.Count
    $currentFolder = if ($savedProgress) { $savedProgress.CurrentFolder } else { 0 }

    foreach ($folder in $foldersToProcess) {
        $currentFolder++
        $sourcePath = Join-Path $UserPath $folder
        $destPath = Join-Path $DestinationPath $folder

        if (Test-Path $sourcePath) {
            # Update progress bar
            Show-ProgressBar -Current $currentFolder -Total $totalFolders -Activity "Copying $folder" -StartTime $startTime

            # Build exclude list for exact file resume
            $excludeFiles = @()
            if ($BackupAnalysis -and $BackupAnalysis.CopiedFiles) {
                if ($BackupAnalysis.CopiedFiles.ContainsKey($folder)) {
                    $excludeFiles = $BackupAnalysis.CopiedFiles[$folder]
                }
            }

            # Build robocopy arguments (hide output to prevent flooding)
            $robocopyArgs = @(
                "`"$sourcePath`"",
                "`"$destPath`"",
                "/MIR",        # Mirror directory
                "/COPY:DAT",   # Copy data, attributes, and timestamps
                "/DCOPY:DAT",  # Copy directory attributes and timestamps
                "/XF", "*.pst", # Exclude PST files
                "/R:3",        # Retry 3 times
                "/W:10",       # Wait 10 seconds between retries
                "/MT:16",      # Multi-threaded copying
                "/LOG+:`"$logFile`"",  # Append to log file
                "/NFL",        # No file list
                "/NDL",        # No directory list
                "/NP"          # No progress percentage
            )

            # Add exclude files for exact resume
            foreach ($excludeFile in $excludeFiles) {
                $robocopyArgs += "/XF"
                $robocopyArgs += "`"$excludeFile`""
            }

            # Save progress before starting folder
            Save-ProgressToLog -LogPath $logFile -CurrentFolder $currentFolder -TotalFolders $totalFolders -CurrentFile $currentFileCount -TotalFiles $totalFiles -CurrentFolderName $folder

            # Start robocopy process (hidden output)
            $process = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -NoNewWindow -PassThru -Wait -WindowStyle Hidden

            # Update file count estimate (rough)
            if (Test-Path $sourcePath) {
                try {
                    $folderFileCount = (Get-ChildItem $sourcePath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne ".pst" }).Count
                    $currentFileCount += $folderFileCount
                } catch {
                    # Estimate if count fails
                    $currentFileCount += 100
                }
            }

            # Save final progress for this folder
            Save-ProgressToLog -LogPath $logFile -CurrentFolder $currentFolder -TotalFolders $totalFolders -CurrentFile $currentFileCount -TotalFiles $totalFiles -CurrentFolderName $folder

            # Status message below progress bar
            $statusMsg = if ($process.ExitCode -le 3) {
                "OK $folder completed successfully"
            } elseif ($process.ExitCode -le 7) {
                "WARN $folder completed with warnings (Exit code: $($process.ExitCode))"
            } else {
                "ERROR $folder failed (Exit code: $($process.ExitCode))"
            }
            Write-Host $statusMsg.PadRight(80) -ForegroundColor $(if ($process.ExitCode -le 3) { "Green" } elseif ($process.ExitCode -le 7) { "Yellow" } else { "Red" })
        } else {
            Write-Host "Skipping $folder (not found)".PadRight(80) -ForegroundColor Gray
        }
    }

    # Process OneDrive folders (already determined above)

    foreach ($oneFolder in $oneDriveFoldersToProcess) {
        $currentFolder++
        if (Test-Path $oneFolder.Source) {
            # Update progress bar
            Show-ProgressBar -Current $currentFolder -Total $totalFolders -Activity "Copying $($oneFolder.Dest)" -StartTime $startTime

            $destPath = Join-Path $DestinationPath $oneFolder.Dest

            # Build exclude list for exact file resume
            $excludeFiles = @()
            if ($BackupAnalysis -and $BackupAnalysis.CopiedFiles) {
                if ($BackupAnalysis.CopiedFiles.ContainsKey($oneFolder.Dest)) {
                    $excludeFiles = $BackupAnalysis.CopiedFiles[$oneFolder.Dest]
                }
            }

            # Build robocopy arguments (hide output)
            $robocopyArgs = @(
                "`"$($oneFolder.Source)`"",
                "`"$destPath`"",
                "/MIR",        # Mirror directory
                "/COPY:DAT",   # Copy data, attributes, and timestamps
                "/DCOPY:DAT",  # Copy directory attributes and timestamps
                "/XF", "*.pst", # Exclude PST files
                "/R:3",        # Retry 3 times
                "/W:10",       # Wait 10 seconds between retries
                "/MT:16",      # Multi-threaded copying
                "/LOG+:`"$logFile`"",  # Append to log file
                "/NFL",        # No file list
                "/NDL",        # No directory list
                "/NP"          # No progress percentage
            )

            # Add exclude files for exact resume
            foreach ($excludeFile in $excludeFiles) {
                $robocopyArgs += "/XF"
                $robocopyArgs += "`"$excludeFile`""
            }

            # Save progress before starting folder
            Save-ProgressToLog -LogPath $logFile -CurrentFolder $currentFolder -TotalFolders $totalFolders -CurrentFile $currentFileCount -TotalFiles $totalFiles -CurrentFolderName $oneFolder.Dest

            # Start robocopy process (hidden output)
            $process = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -NoNewWindow -PassThru -Wait -WindowStyle Hidden

            # Update file count estimate
            if (Test-Path $oneFolder.Source) {
                try {
                    $folderFileCount = (Get-ChildItem $oneFolder.Source -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne ".pst" }).Count
                    $currentFileCount += $folderFileCount
                } catch {
                    $currentFileCount += 100
                }
            }

            # Save final progress for this folder
            Save-ProgressToLog -LogPath $logFile -CurrentFolder $currentFolder -TotalFolders $totalFolders -CurrentFile $currentFileCount -TotalFiles $totalFiles -CurrentFolderName $oneFolder.Dest

            # Status message below progress bar
            $statusMsg = if ($process.ExitCode -le 3) {
                "OK $($oneFolder.Dest) completed successfully"
            } elseif ($process.ExitCode -le 7) {
                "WARN $($oneFolder.Dest) completed with warnings (Exit code: $($process.ExitCode))"
            } else {
                "ERROR $($oneFolder.Dest) failed (Exit code: $($process.ExitCode))"
            }
            Write-Host $statusMsg.PadRight(80) -ForegroundColor $(if ($process.ExitCode -le 3) { "Green" } elseif ($process.ExitCode -le 7) { "Yellow" } else { "Red" })
        } else {
            Write-Host "Skipping $($oneFolder.Dest) (not found)".PadRight(80) -ForegroundColor Gray
        }
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

            Write-Host "`nAvailable storage devices:" -ForegroundColor Yellow
            for ($i = 0; $i -lt $devices.Count; $i++) {
                $device = $devices[$i]
                Write-Host "  $($i + 1). $($device.Drive) [$($device.Label)] - $($device.Size) (Free: $($device.Free)) [$($device.Type)]" -ForegroundColor Green
            }

            do {
                $deviceChoice = Read-Host "`nSelect device number (1-$($devices.Count))"
                $deviceChoice = [int]$deviceChoice
            } while ($deviceChoice -lt 1 -or $deviceChoice -gt $devices.Count)

            $BackupLocation = $devices[$deviceChoice - 1].Drive
        } catch {
            Handle-Error "Failed to get storage devices: $($_.Exception.Message)" -Critical $true
        }
    }

    Write-Host "Selected device: $BackupLocation" -ForegroundColor Green

    # Handle resume logic
    $analysis = $null
    if ($isResume) {
        $existingBackups = Get-ExistingBackups -DevicePath $BackupLocation
        if ($existingBackups.Count -eq 0) {
            Write-Host "No existing backups found on $BackupLocation" -ForegroundColor Yellow
            Write-Host "Starting new backup instead..." -ForegroundColor Yellow
            $isResume = $false
        } else {
            Write-Host "`nExisting backup folders found:" -ForegroundColor Yellow
            for ($i = 0; $i -lt $existingBackups.Count; $i++) {
                $backup = $existingBackups[$i]
                Write-Host "  $($i + 1). $($backup.Name) (Modified: $($backup.LastWriteTime))" -ForegroundColor Green
            }

            do {
                $backupChoice = Read-Host "`nSelect backup to continue (1-$($existingBackups.Count))"
                $backupChoice = [int]$backupChoice
            } while ($backupChoice -lt 1 -or $backupChoice -gt $existingBackups.Count)

            $selectedBackup = $existingBackups[$backupChoice - 1]
            $BackupFolder = $selectedBackup.Name
            $fullBackupPath = $selectedBackup.FullName

            Write-Host "Resuming backup: $($selectedBackup.Name)" -ForegroundColor Green

            # Analyze what's already been backed up
            $analysis = Compare-BackupProgress -UserPath $userProfilePath -BackupPath $fullBackupPath

            Write-Host "`nBackup Progress Analysis:" -ForegroundColor Cyan
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
                Write-Host "Would you like to verify/refresh the backup anyway? (y/N): " -NoNewline
                $verify = Read-Host
                if ($verify -ne 'y' -and $verify -ne 'Y') {
                    Write-Host "Backup verification skipped." -ForegroundColor Yellow
                    Write-Host "`nPress any key to exit..."
                    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                    exit 0
                }
            }
        }
    }

    # Get backup folder name if not provided
    if (-not $BackupFolder) {
        $BackupFolder = Read-Host "`nEnter backup folder name (or press Enter for default)"
        if (-not $BackupFolder) {
            $BackupFolder = "$Username-Backup-" + (Get-Date -Format "yyyyMMdd-HHmmss")
        }
    }

    $fullBackupPath = Join-Path $BackupLocation $BackupFolder
    if (-not (Test-Path $fullBackupPath)) {
        try {
            New-Item -ItemType Directory -Path $fullBackupPath -Force | Out-Null
        } catch {
            Handle-Error "Failed to create backup directory: $($_.Exception.Message)" -Critical $true
        }
    }

    # Calculate backup size estimate
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
        if ($isResume -and $analysis) {
            Start-UserBackup -UserPath $userProfilePath -DestinationPath $fullBackupPath -UserName $Username -BackupAnalysis $analysis
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
        Write-Host "  Session log: $global:SessionLog"
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
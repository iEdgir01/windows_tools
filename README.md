# Windows User Backup Tool

A PowerShell script for fast, reliable user data backup using Robocopy with recovery features.

## Features

- **Interactive prompts** for user selection, storage device, and backup folder
- **Smart filtering** - only backs up user data (Desktop, Downloads, Documents, Pictures, Videos, Music)
- **Recovery features** - handles USB disconnects, retries failed copies
- **Progress tracking** - shows current folder being copied and completion status
- **Time estimation** - calculates estimated backup time based on data size
- **Multi-threaded copying** - uses Robocopy with 16 threads for maximum speed
- **Detailed logging** - creates backup_log.txt with full operation details

## Remote Execution

### Normal Mode (Recommended)

```cmd
powershell -Command "iwr -useb 'https://raw.githubusercontent.com/iEdgir01/windows_tools/main/UserBackup.ps1' | iex"
```

### Debug Mode (For Troubleshooting)

```cmd
powershell -Command "iwr -useb 'https://raw.githubusercontent.com/iEdgir01/windows_tools/main/UserBackupDebug.ps1' | iex"
```

The debug version opens a separate console window with detailed logging to help troubleshoot any issues.

## Local Execution

### Normal Version
```powershell
.\UserBackup.ps1
```

### Debug Version
```powershell
.\UserBackupDebug.ps1
```

## Parameters (Optional)

You can skip prompts by providing parameters to either version:

```powershell
.\UserBackup.ps1 -Username "JohnDoe" -BackupLocation "E:" -BackupFolder "Backup_2024"
.\UserBackupDebug.ps1 -Username "JohnDoe" -BackupLocation "E:" -BackupFolder "Backup_2024"
```

## What Gets Backed Up

The script backs up these user folders:
- Desktop
- Downloads
- Documents
- Pictures
- Videos
- Music

## What Gets Excluded

- Application data (AppData)
- System files
- Shortcuts
- Temporary files
- Program files

## Robocopy Features Used

- `/MT:16` - Multi-threaded copying (16 threads)
- `/R:3` - Retry failed copies 3 times
- `/W:10` - Wait 10 seconds between retries
- `/E` - Copy subdirectories including empty ones
- `/COPY:DAT` - Copy data, attributes, and timestamps

## Requirements

- Windows PowerShell 5.0 or later
- Administrative privileges may be required for some user profiles
- Sufficient free space on backup destination
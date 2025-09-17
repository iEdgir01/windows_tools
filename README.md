# Windows User Backup & Restore Tools

PowerShell scripts for fast, reliable user data backup and restore using Robocopy with recovery features and merge capabilities.

## Features

### Backup Tool (UserBackup.ps1)
- **Interactive prompts** for user selection, storage device, and backup folder
- **Smart filtering** - backs up user data including OneDrive synced folders
- **PST exclusion** - automatically excludes large Outlook PST files
- **Recovery features** - handles USB disconnects, retries failed copies
- **Progress tracking** - shows current folder being copied and completion status
- **Time estimation** - calculates estimated backup time based on data size
- **Multi-threaded copying** - uses Robocopy with 16 threads for maximum speed
- **Detailed logging** - creates backup_log.txt with full operation details

### Restore Tool (UserRestore.ps1)
- **Target user selection** - choose which user to restore data to
- **Backup discovery** - automatically finds backup folders on storage devices
- **Single restore** - restore one backup to a user account
- **Merge functionality** - combine multiple backups into one user account
- **Smart folder mapping** - correctly maps OneDrive folders back to OneDrive locations
- **Size estimation** - calculates restore size and time before starting
- **Progress tracking** - real-time status updates during restore process

## Remote Execution

### Backup Scripts

**Normal Mode (Recommended)**
```cmd
powershell -Command "iwr -useb 'https://raw.githubusercontent.com/iEdgir01/windows_tools/main/UserBackup.ps1' | iex"
```

**Debug Mode (For Troubleshooting)**
```cmd
powershell -Command "iwr -useb 'https://raw.githubusercontent.com/iEdgir01/windows_tools/main/UserBackupDebug.ps1' | iex"
```

The debug version opens a separate console window with detailed logging to help troubleshoot any issues.

### Restore Script

```cmd
powershell -Command "iwr -useb 'https://raw.githubusercontent.com/iEdgir01/windows_tools/main/UserRestore.ps1' | iex"
```

## Local Execution

### Backup Scripts
```powershell
.\UserBackup.ps1          # Normal backup
.\UserBackupDebug.ps1     # Debug backup with detailed logging
```

### Restore Script
```powershell
.\UserRestore.ps1         # Restore with merge capabilities
```

## Parameters (Optional)

### Backup Scripts
You can skip prompts by providing parameters:

```powershell
# Backup scripts
.\UserBackup.ps1 -Username "JohnDoe" -BackupLocation "E:" -BackupFolder "Backup_2024"
.\UserBackupDebug.ps1 -Username "JohnDoe" -BackupLocation "E:" -BackupFolder "Backup_2024"
```

### Restore Script
```powershell
# Restore script
.\UserRestore.ps1 -TargetUser "JohnDoe" -SourceLocation "E:" -BackupFolders @("Backup_2024", "Backup_2023")
```

## What Gets Backed Up

### Standard User Folders
- Desktop
- Downloads
- Documents
- Pictures
- Videos
- Music

### OneDrive Synced Folders (when present)
- OneDrive\Desktop
- OneDrive\Documents
- OneDrive\Pictures
- OneDrive\Videos
- OneDrive\Music

## What Gets Excluded

- **PST files** - Outlook data files (*.pst)
- Application data (AppData)
- System files
- Shortcuts
- Temporary files
- Program files

## Robocopy Features Used

### Backup Operations
- `/MIR` - Mirror directory (complete copy, creates dirs, deletes extras)
- `/COPY:DAT` - Copy data, attributes, and timestamps
- `/XF *.pst` - Exclude PST files
- `/MT:16` - Multi-threaded copying (16 threads for backup)
- `/R:3` - Retry failed copies 3 times
- `/W:10` - Wait 10 seconds between retries

### Restore Operations
- `/E` - Copy subdirectories including empty ones
- `/COPY:DAT` - Copy data, attributes, and timestamps
- `/MT:8` - Multi-threaded copying (8 threads for restore)
- Smart merge handling for multiple backup sources

## Restore Workflow

The restore script provides flexible options for data recovery:

1. **Target User Selection** - Choose which user account to restore data to
2. **Storage Device Detection** - Automatically detects and lists available drives
3. **Backup Discovery** - Scans for folders containing backup data structure
4. **Restore Options**:
   - **Single Restore** - Restore one backup folder to the target user
   - **Merge Multiple** - Combine data from multiple backup folders into one user account
5. **Smart Folder Mapping**:
   - Standard folders (Desktop, Documents, etc.) → `C:\Users\[TargetUser]\[Folder]`
   - OneDrive folders → `C:\Users\[TargetUser]\OneDrive\[Folder]`
6. **Progress Tracking** - Real-time status updates and completion reporting

### Merge Functionality

When merging multiple backups:
- Files from later backups overwrite files from earlier backups if they have the same name
- All unique files from all selected backups are preserved
- Perfect for consolidating data from multiple users or time periods

## Requirements

- Windows PowerShell 5.0 or later
- Administrative privileges may be required for some user profiles
- Sufficient free space on backup destination (for backup operations)
- Sufficient free space on target user profile (for restore operations)
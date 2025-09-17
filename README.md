# Windows User Backup & Restore Tools

PowerShell scripts for fast, reliable user data backup and restore using Robocopy with recovery features and merge capabilities.

## Features

### Backup Tool (UserBackup.ps1)
- **Interactive prompts** for user selection, storage device, and backup folder
- **Smart filtering** - backs up user data including OneDrive synced folders
- **PST exclusion** - automatically excludes large Outlook PST files
- **Resume functionality** - continues interrupted backups with exact file-level tracking
- **Progress tracking** - visual progress bar with ETA and real-time status
- **Time estimation** - calculates estimated backup time based on data size
- **Multi-threaded copying** - uses Robocopy with optimized thread count for reliability
- **Detailed logging** - creates backup_log.txt with full operation details and progress markers
- **Enhanced error handling** - detailed exit code interpretation and retry logic

### Restore Tool (UserRestore.ps1)
- **Target user selection** - choose which user to restore data to
- **Backup discovery** - automatically finds backup folders on storage devices
- **Single restore** - restore one backup to a user account
- **Merge functionality** - combine multiple backups into one user account
- **Smart folder mapping** - correctly maps OneDrive folders back to OneDrive locations
- **Size estimation** - calculates restore size and time before starting
- **Progress tracking** - visual progress bar with ETA and real-time status
- **Enhanced conflict resolution** - detailed file comparison with smart merging options

## Remote Execution

### Backup Script

```cmd
powershell -Command "iwr -useb 'https://raw.githubusercontent.com/iEdgir01/windows_tools/main/UserBackup.ps1' | iex"
```

### Restore Script

```cmd
powershell -Command "iwr -useb 'https://raw.githubusercontent.com/iEdgir01/windows_tools/main/UserRestore.ps1' | iex"
```

## Local Execution

### Backup Script
```powershell
.\UserBackup.ps1          # User backup with resume functionality
```

### Restore Script
```powershell
.\UserRestore.ps1         # Restore with merge capabilities
```

## Parameters (Optional)

### Backup Script
You can skip prompts by providing parameters:

```powershell
# User backup
.\UserBackup.ps1 -Username "JohnDoe" -BackupLocation "E:" -BackupFolder "Backup_2024"
```

### Restore Script
```powershell
# Interactive restore (asks about conflicts)
.\UserRestore.ps1 -TargetUser "JohnDoe" -SourceLocation "E:" -BackupFolders @("Backup_2024", "Backup_2023")

# Automated restore with conflict resolution
.\UserRestore.ps1 -TargetUser "JohnDoe" -SourceLocation "E:" -ConflictResolution "IfNewer"
```

**ConflictResolution Options:**
- `"Ask"` - Interactive prompts for each conflict (default)
- `"Skip"` - Keep existing files, skip conflicts
- `"Overwrite"` - Replace all conflicting files
- `"IfNewer"` - Only overwrite if new file is more recent

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
- `/MT:8` - Multi-threaded copying (8 threads for stability)
- `/R:5` - Retry failed copies 5 times
- `/W:30` - Wait 30 seconds between retries
- `/SKIP:SL` - Skip symbolic links to avoid issues

### Restore Operations
- `/E` - Copy subdirectories including empty ones
- `/COPY:DAT` - Copy data, attributes, and timestamps
- `/MT:8` - Multi-threaded copying (8 threads for restore)
- `/R:5` - Retry failed copies 5 times
- `/W:30` - Wait 30 seconds between retries
- `/SKIP:SL` - Skip symbolic links to avoid issues
- `/IS` - Include Same files (used in merge operations for consistency)
- `/IT` - Include Tweaked files (used in merge operations for overwrites)
- Smart merge handling with explicit conflict resolution

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

When merging multiple backups, the script processes them in the order selected:

1. **First backup** - Copied normally to the target user
2. **Subsequent backups** - Conflicts are detected and user chooses resolution:

#### **Interactive Conflict Resolution**

When file conflicts are detected, you choose how to handle them:

1. **Skip conflicts** - Keep existing files, don't overwrite anything
2. **Overwrite all** - Replace all conflicting files with new versions
3. **Keep newer files only** - Smart date-based replacement (newer files win)
4. **Review individually** - Decide file-by-file with enhanced details:
   - **Enhanced date display**: Shows exact timestamps and file age
   - **Clear newer indicator**: Highlights which file is more recent and by how much
   - **Multiple options per file**: (O)verwrite, (S)kip, Keep (N)ewer, (A)bort, or apply to (A)ll
   - **Apply to all remaining**: After reviewing one conflict, apply the same decision to all remaining conflicts

#### **Enhanced Conflict Display Example**
```
Conflict: Documents\ProjectPlan.docx
  Existing: 2,450,123 bytes
            Last modified: 2024-01-15 09:30:22 (25 days ago)
  New:      2,551,890 bytes
            Last modified: 2024-01-20 14:22:15 (20 days ago)
  → New file is NEWER by 5 days, 4 hours

(O)verwrite, (S)kip, Keep (N)ewer, (A)bort folder, or apply to (A)ll remaining?
```

**Benefits of Enhanced Resolution**:
- **Safe merging** - No accidental overwrites of important files
- **Informed decisions** - See exact dates, file sizes, and age comparisons
- **Flexible handling** - Different strategies per backup or folder
- **Batch decisions** - Apply same choice to multiple conflicts
- **Smart newer detection** - Automatically identifies which file is more recent
- **Abort option** - Stop if conflicts are too complex to resolve

## Resume Functionality

The backup script includes advanced resume capabilities:

### **Automatic Resume Detection**
- Detects incomplete backups on startup
- Analyzes existing log files to determine progress
- Offers to continue from where backup was interrupted

### **Exact File-Level Resume**
- Tracks individual files copied for each folder
- Creates dynamic exclusion lists for already-copied files
- Avoids redundant file copying during resume operations

### **Progress Preservation**
- Saves progress markers to log files in JSON format
- Maintains accurate progress tracking across resume sessions
- Displays clear status of missing vs incomplete folders

## Requirements

- Windows PowerShell 5.0 or later
- Administrative privileges may be required for some user profiles
- Sufficient free space on backup destination (for backup operations)
- Sufficient free space on target user profile (for restore operations)
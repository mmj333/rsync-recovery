# Rsync Recovery Script

A smart recovery script for failing drives that prioritizes important data and handles interrupted transfers gracefully.

## 🛑 Before you start - physical risk to a failing drive

**This tool is for recoveries where you have judged the drive to be at low risk of
mechanical / head / platter damage** - e.g. logical corruption, a deleted or
damaged partition, a controller/firmware fault, or a drive that still reads but
has bad sectors.

**Powering on and running a failing drive - HDD *or* SSD - for any length of time
can make your data permanently unrecoverable.** On a hard drive, a failing head
can crash into and score the platters, destroying data that was previously
recoverable; on any drive, continued operation can accelerate the failure. Every
additional minute of runtime is a gamble.

**If your data is highly critical and you are not willing to accept ANY risk of
losing it, do not run this tool - or any DIY recovery tool.** Power the drive
down, leave it unplugged, and send it to a professional data-recovery service that
has a **clean room** and proper handling procedures for failing drives. A failed
DIY attempt can make a later professional recovery harder, more expensive, or
impossible.

**Stop immediately and consult a professional** if the drive makes clicking,
buzzing, grinding, or beeping noises; fails to spin up; gets unusually hot; or
repeatedly disconnects under read errors.

> **No warranty.** This software is provided as-is, with no warranty and no
> guarantees. Data recovery is inherently risky; you use it entirely at your own
> risk. Treat the failing drive as a **read-only source** and recover **to a
> separate, healthy destination**.

## Features

### Core Recovery Capabilities
- **Resume Support**: Safely interrupt with Ctrl+C and resume later with `--resume`
- **Fast Resume Mode**: Use `--fast-resume` to skip already-copied files using manifest tracking
- **Smart Priority**: Copies Pictures/Documents/Desktop first, AppData last
- **Failing Drive Optimized**: Single-pass directory scanning, minimal disk seeks
- **File-Type Filtering**: Option to recover only specific file types (pictures, videos, documents, music)
- **Root-Level Prioritization**: Smart ordering for external drives and mixed content
- **Recovery Presets**: Profession-specific priorities (Family, Photographer, Business, Developer, etc.)
- **Smart Deferral**: Large non-priority files copied last to maximize important file recovery

### Recovery Modes
1. **Specific Folder/Files**: Copy a single user folder or directory tree
2. **Full Drive Recovery**: Extract user data from system drives, skipping Windows/System folders
3. **Copy Everything**: Full sync with no exclusions - perfect for external drives

### File-Type Recovery (New!)
Filter recovery to specific file types:
- **Pictures**: jpg, png, raw formats (CR2, NEF, ARW), HEIC, PSD, SVG, etc.
- **Videos**: mp4, avi, mkv, mov, professional formats, etc.
- **Documents**: Office files, PDFs, text, ebooks, spreadsheets
- **Music**: mp3, flac, wav, m4a, and other audio formats

### Smart Exclusions
Automatically skips (by default):
- Temporary files and caches
- Browser caches
- System files (pagefile.sys, hiberfil.sys)
- Cloud sync caches (OneDrive, Dropbox)
- Development caches (node_modules, .git)

Optional exclusions:
- Virtual machine files (VMDKs, VHDs)
- ISO files
- Installers in Downloads
- Steam libraries

### Symlink Handling
- Safely skips Windows junction points/symlinks
- Creates `symlinks_map.txt` showing what was skipped
- Prevents errors on incompatible filesystems (exFAT, FAT32)

### Fast Resume Mode (Manifest Mode)
- Tracks completed files in `recovery_manifest_[timestamp].txt`
- Manifest saved on Desktop during recovery for visibility
- Moved to destination only after successful completion
- On resume, skips files already in the manifest
- Dramatically reduces resume time on failing drives
- No need to re-stat thousands of already-copied files
- Enable with `--fast-resume` or choose during interactive setup

### Easy Access Mode
- Reorganizes recovered files for easier user access
- Automatically detects single-user vs multi-user setups
- For single users: Moves their folders directly to recovery root
- Groups system/program folders into "Other files" folder
- Creates `REORGANIZATION_INFO.txt` documenting changes
- Choose during interactive setup (default) or keep original structure

### Recovery Presets (New in v1.5.0)
Choose a preset based on customer type to optimize file priorities:
- **Family/Personal**: Photos and videos first
- **Photographer (Exports)**: Edited photos, then RAW files
- **Photographer (RAW)**: Original RAW files first
- **Business/Office**: Documents, QuickBooks, emails
- **Developer**: Source code, git repos, configs
- **Gamer/Streamer**: Save games, recordings
- **Student/Academic**: Homework, research, thesis
- **Balanced**: General purpose (default)

### Smart File Deferral (New in v1.5.0)
- Automatically identifies large non-priority files (>100MB)
- Defers them until after all important data is copied
- Examples: ISO files in Pictures folder, VM images in Documents
- Maximizes file count from failing drives
- Auto-continues after 10 seconds if unattended

## Usage

### Interactive Mode (Recommended)
```bash
./rsync_recovery.sh
```

### Resume Previous Recovery
```bash
./rsync_recovery.sh --resume       # Normal resume (checks all files)
./rsync_recovery.sh --fast-resume   # Fast resume (skips files in manifest)
```

### Example Workflow
1. Start recovery: `./rsync_recovery.sh`
2. Choose recovery mode (folder or full drive)
3. Optionally filter by file type
4. Select source and destination
5. Choose manifest mode for fast resume (recommended)
6. Choose file organization (easy mode recommended)
7. Monitor progress
8. If interrupted, resume with: `./rsync_recovery.sh --fast-resume`
9. Files are automatically reorganized for easy access

## Installation

1. Copy script to recovery system:
```bash
cp rsync_recovery.sh /path/to/recovery/location/
chmod +x rsync_recovery.sh
```

2. Ensure rsync is installed:
```bash
sudo apt-get install rsync  # Debian/Ubuntu
```

## Output Files

### In the destination directory:
- `folder_summary.txt` - List of processed/skipped folders
- `symlinks_map.txt` - Map of skipped symlinks and their targets
- `recovery_manifest.txt` - List of successfully copied files (when using manifest mode)
- `REORGANIZATION_INFO.txt` - Summary of file reorganization (if easy mode used)

### On the source system:
- Recovery settings saved in `~/.rsync_recovery/` for resume capability
- Settings include source/dest paths, options, and timestamp
- Last 10 recovery sessions are kept

## Design Philosophy

This script was designed for real-world data recovery scenarios:
- Minimizes reads on failing drives (single-pass scanning)
- Prioritizes irreplaceable data (photos, documents)
- Handles Windows and Mac folder structures
- Works with any filesystem that supports rsync
- Clear progress indication and error reporting
- Smart handling of external drives with backup folders
- Processes folders in logical order, not filesystem order

### Root-Level Processing Order (v1.4.0+)
When processing full drives, folders are now copied in this priority order:
1. **Phase 1**: Priority folders (containing Documents, Pictures, Photos, etc.)
2. **Phase 2**: Root-level files
3. **Phase 3**: Backup folders (date patterns, "backup", "computer", iPhone/iPad folders)
4. **Phase 4**: Normal folders
5. **Phase 5**: System folders (if included)
6. **Phase 6**: $RECYCLE.BIN (only in "Copy Everything" mode, processed last)

## Future Enhancements

- Windows utility to recreate symlinks from `symlinks_map.txt`
- Size estimation improvements
- Network destination support
- Parallel transfer options

## License

Free to use for data recovery purposes. Please share improvements!
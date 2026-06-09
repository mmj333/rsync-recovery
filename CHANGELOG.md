# Changelog

## [1.9.3] - 2025-08-18

### Changed
- **Redesigned sudo handling for better user experience**
  - Removed automatic sudo prompt at startup
  - Recovery menu shows sudo status and option to restart with sudo
  - SMART health data collected immediately after source selection (if running with sudo)
  - Shows drive health status with visual indicators (✓ for PASSED, ⚠️ for FAILED)
  - Warns and prompts for confirmation if drive is failing
  - Shows critical SMART attributes (reallocated sectors, pending sectors, etc.)
  - No sudo attempts in drive_info_functions.sh - only uses sudo if already available

### Added
- **Option 'S' in recovery menu to restart with sudo**
  - Only shown when not already running with sudo
  - Enables full features: SMART health data and partition mounting

### Note
- Running with sudo is recommended for professional recovery work
- Sudo provides immediate drive health assessment to identify failing drives

## [1.9.2] - 2025-08-18

### Fixed
- **File-type filtering now properly excludes temp/cache files**
  - Fixed issue where Temporary Internet Files were copied when using Photos/Videos Only preset
  - Rsync exclude patterns now come BEFORE include patterns in command
  - Added explicit excludes for cache directories at start of file filtering
  - Prevents copying of cached images/videos from browser temp folders

- **Recovery verification now checks correct subfolder**
  - Recovery settings now store the actual final destination path
  - When subfolder is created (e.g., 12345_ClientName_OS), verification checks only that folder
  - Resume operations use the correct subfolder path
  - Shows full path in recovery history

### Technical Details
- Rsync evaluates patterns in order; first match wins
- When using `--include='*.jpg'`, it was matching before `--exclude='Temporary Internet Files/'`
- Now cache folders are excluded first, preventing any matches inside them
- Added FINAL_DEST_PATH to recovery settings for accurate verification

## [1.9.1] - 2025-08-18

### Added
- **Enhanced partition display with used space calculations**
  - Shows actual used space in GB/TB next to percentages (e.g., "32% (117GB)")
  - Calculates used space based on total size and percentage
  - Automatically formats in appropriate units (KB/MB/GB/TB)
  - Works without requiring `bc` for calculations

### Fixed
- **Decimal arithmetic errors in partition analyzer**
  - Fixed "syntax error: invalid arithmetic operator" for drives with decimal sizes (1.9T)
  - Added proper integer conversion for bash arithmetic
  - Added validation for empty/non-numeric scores

### Improved
- **System partition filtering**
  - Better pattern matching for system partitions (winre, diagnostics, etc.)
  - Combination scoring based on size + label
  - Filters out partitions like ESP, DIAGS, WINRETOOLS, PBR Image

- **Source/Destination scoring**
  - CPR_Backup drives now heavily penalized as sources (-50 to -70 points)
  - Backup-labeled drives deprioritized as sources
  - Better differentiation between source and destination drives

## [1.9.0] - 2025-08-18

### Added
- **Customer/Ticket tracking system**
  - Prompts for ticket number and customer name at start
  - Remembers last ticket info for quick reuse
  - Includes info in recovery folder names and documentation

- **Smart subfolder naming**
  - Format: `[TicketNum]_[CustomerName]_[DriveID]`
  - DriveID uses first 5 chars of: label, size, or mount point
  - Only creates subfolder if destination has existing files
  - Ignores system files when checking if destination is empty

- **Drive information documentation**
  - Creates DRIVE_INFO.txt with complete drive details
  - Includes model, serial, size, filesystem info
  - Records recovery settings and timestamp
  - Attempts to get SMART data if available

- **Enhanced verification**
  - Automatically detects if files are in a subfolder
  - Checks common patterns like volume names or ticket folders
  - No need to manually specify subfolder path

### Improved
- Better organization for multi-customer recoveries
- Professional documentation for each recovery job
- Easier tracking of which recovery belongs to which customer

## [1.8.6] - 2025-08-18

### Added
- **Performance warnings for file-type filtering**
  - Added prominent red warnings about CPU-intensive scanning phase
  - Warns that initial scan can take 10+ minutes on large drives
  - Recommends against using on failing/slow drives
  - Added warning to preset menu showing which presets use filtering
  - Clear messaging during filter preparation vs actual scanning

### Improved
- **User feedback during file-type filtering**
  - Clarified that "Building filters" is quick preparation phase
  - Added warning when rsync scanning actually begins
  - Explains high CPU usage during initial file scan

## [1.8.5] - 2025-08-18

### Added
- **Smart unmounted partition detection and mounting**
  - Shows unmounted partitions with backup-related labels (backup, CPR_Backup, recovery, data, storage)
  - Offers to mount these partitions directly from the destination menu
  - Creates mount points automatically under /media/$USER/
  - Supports various filesystem types (NTFS, exFAT, ext4, etc.)

### Changed
- **Source drive exclusion from destination menu**
  - The source drive is now automatically excluded from destination choices
  - Prevents accidental selection of source as destination
  - Passes source device information from selection to destination menu

### Technical Implementation
- Added mount_partition() function to handle mounting with proper filesystem detection
- Modified show_destination_menu() to accept source device parameter for exclusion
- Enhanced destination selection to handle unmounted partition mounting workflow

## [1.8.3] - 2025-08-15

### Added
- **Special handling for photo library packages**
  - Automatically includes entire contents of .photoslibrary directories
  - Includes .photolibrary (older iPhoto) and .aplibrary (Aperture)
  - Captures ALL files inside regardless of extension (databases, caches, etc.)
  - Essential for preserving edit history and library structure

- **Lightroom catalog support**
  - Includes .lrcat catalog files
  - Includes .lrdata preview directories
  - Includes any Lightroom* directories

- **Photo Booth library support**
  - Includes "Photo Booth Library" directories
  - Includes Pictures/Photo Booth paths

- **Other photo management tools**
  - Capture One catalogs (.c1catalog, .coc1catalog packages)
  - Darktable libraries (.darktable directories)

- **Additional metadata formats**
  - Added dop (DxO), pp3 (RawTherapee), ctx (Capture One) to picture extensions

### Technical Implementation
- Uses rsync's *** pattern to include all subdirectory contents
- Ensures complete library packages are copied even with file filtering
- Handles the symlink issue by copying referenced files

## [1.8.2] - 2025-08-15

### Added
- **Photos & Videos Only preset**
  - New preset specifically for media recovery
  - Includes all photo and video formats
  - Includes iPhoto/Photos library packages (.photoslibrary directories)
  - Excludes documents and other file types
  - Perfect for customers who just want their memories back

### Enhanced
- **Family preset clarification**
  - Now explicitly mentions iPhoto/Photos libraries are included
  - These are directory packages that contain entire photo databases

### Fixed
- **Back navigation from source selection**
  - Changed continue to break to properly exit selection loop
  - Added check for empty source_path to return to main menu

### Technical Note
- Photo libraries (.photoslibrary) are directories, not files
- They're automatically included when copying Pictures folders
- Contains database, originals, edits, and metadata

## [1.8.1] - 2025-08-15

### Fixed
- **Partition analyzer integer expression errors**
  - Fixed "integer expression expected" errors when parsing usage percentages
  - Added validation to ensure numeric values before comparisons
  - Now properly handles empty or non-numeric usage data

### Added
- **Mac filesystem warnings**
  - Detects HFS+ filesystems and warns about unreliable Linux write support
  - Detects APFS filesystems and warns about no Linux write support
  - Visual indicators: ⚠️ for HFS+, ❌ for APFS
  - Helps prevent data corruption when selecting Mac drives as destinations

### Improved
- More robust partition analysis with better error handling
- Safer recommendations for cross-platform recovery scenarios

## [1.8.0] - 2025-08-15

### Added
- **Preset-first workflow**
  - Recovery preset selection now happens immediately after mode choice
  - Presets configure most settings automatically
  - Reduces questions from ~10 to ~3 for most users
  - Added "Custom" preset option for manual configuration
  
- **Enhanced preset menu (preset_menu.sh)**
  - Clear descriptions for each preset type
  - Shows what settings each preset applies
  - Visual summary of selected configuration
  - Back option to return to main menu

### Changed
- **Streamlined user experience**
  - Preset drives the configuration instead of many questions
  - Only asks detailed questions for "Custom" preset
  - Program Files, Steam, file filtering questions only for custom
  - File structure preference respects preset defaults
  
- **Preset auto-configuration**
  - Family preset: Pictures, videos, docs, easy organization
  - Business preset: Documents, includes Program Files
  - Developer preset: All files, keeps structure
  - Gamer preset: Videos, screenshots, Steam libraries
  - Each preset sets appropriate defaults

### Improved
- Much faster setup for common recovery scenarios
- Clearer understanding of what will be recovered
- Less overwhelming for non-technical users
- Power users can still customize with option 9

## [1.7.4] - 2025-08-15

### Fixed
- **Continue statement bug**
  - Changed incorrect "continue 2" to "continue"
  - Was trying to break out of two loops but only in one
  
- **Code formatting**
  - Fixed indentation issues in source selection block
  - Properly aligned if-else-fi structure

### Verified
- All variables properly initialized before use
- No infinite loop possibilities
- Proper error handling throughout
- Variables correctly quoted for spaces

## [1.7.3] - 2025-08-15

### Fixed
- **Critical navigation flow bugs**
  - Fixed GO_BACK_TO_SOURCE variable scoping issue
  - Now properly declared before destination loop
  - Back navigation from destination to source now works correctly
  
- **Variable initialization**
  - Added USE_MANIFEST and FILE_STRUCTURE initialization
  - Removed duplicate skip_temp declaration
  
- **Error handling**
  - Changed exit 1 to continue for recoverable errors
  - Users can now retry after errors instead of script exiting
  - Added "Press Enter to continue" prompts
  
- **Menu validation**
  - Added validation for invalid menu choices
  - Shows error and returns to menu for invalid input
  
- **Recent recoveries flow**
  - Changed return to continue so menu loop continues
  - Prevents exiting entire function after viewing recent recoveries

## [1.7.2] - 2025-08-15

### Added
- **Back navigation in menus**
  - Can type 'b' or 'B' to go back at most menu prompts
  - Main menu now loops until user selects Exit (option 0)
  - Source selection: 'B' returns to main menu
  - Destination selection: 'B' returns to source selection
  - Program Files question: 'b' returns to main menu
  - Improves user experience when making selections

### Changed
- Interactive mode now wrapped in main loop
- Source/destination selection wrapped in loop for back navigation
- Added exit option (0) to main menu

## [1.7.1] - 2025-08-15

### Changed
- **Disabled directory scanning in partition analyzer**
  - Removed directory checks to avoid stressing failing drives
  - Analysis now based only on filesystem type, labels, and space usage
  - Directory scanning code preserved as comments for future "healthy drive" mode
  - Prevents potential crashes when analyzing source drives

### Safety
- No longer performs directory lookups on potentially failing drives
- Maintains intelligent recommendations without risky I/O operations

## [1.7.0] - 2025-08-15

### Added
- **Partition Selection Menus**
  - Smart source selection menu with partition analysis
  - Intelligent destination selection with recommendations
  - Analyzes filesystem types, usage, and labels
  - Prioritizes data partitions for source selection
  - Recommends empty/backup partitions for destinations
  - Shows mount points, sizes, and free space
  - Visual indicators for recommended vs unsuitable partitions

### Features
- **Source Menu Logic**
  - Prefers Windows/Mac filesystems over Linux
  - Identifies partitions with user data folders
  - Warns about system partitions
  - Allows drilling into specific folders on drives
  - Suggests Users folder for full drive sources

- **Destination Menu Logic**
  - Prioritizes partitions labeled "CPR_Backup" or similar
  - Prefers nearly empty partitions (< 50% used)
  - Shows free space for each partition
  - Allows creating new recovery folders
  - Warns about system partitions

### Technical
- Added partition_analyzer.sh module
- Uses lsblk and blkid for partition detection
- Scoring system for intelligent recommendations
- Falls back to manual entry if analyzer unavailable

## [1.6.0] - 2025-08-14

### Added
- **Comprehensive file format coverage**
  - Picture formats: Added 30+ formats including `jpe`, `jfif`, `aae`, `xmp`, `psb`, `jp2`, `j2k`, `tga`, `iiq`, `braw`, etc.
  - Video formats: Added 35+ formats including `h264`, `h265`, `braw`, `r3d`, `dav`, `lrv`, `thm`, `gifv`, etc.
  - Now catches iPhone edit files (.aae), GoPro companion files, security camera formats, and professional RAW formats
  - Organized with common formats first for efficiency

### Rationale
- When filtering to ONLY copy pictures/videos, we must be comprehensive
- Don't want to leave behind any photo or video files
- Includes companion files (AAE, XMP, LRV, THM) that are important

## [1.5.4] - 2025-08-14

### Changed
- **Consistent manifest timestamps**
  - All manifests for a recovery session use the same timestamp
  - Desktop manifest: `rsync_recovery_manifest_DriveName_20250814_093045.txt`
  - Destination manifest: `recovery_manifest_DriveName_20250814_093045.txt`
  - Prevents conflicts when recovering same drive multiple times
  - Resume finds most recent manifest by pattern matching

### Technical
- Added MANIFEST_TIMESTAMP global variable
- Timestamp generated once at start of recovery
- Resume logic updated to find manifests by pattern
- Manifest timestamp saved in recovery settings

## [1.5.3] - 2025-08-13

### Added
- **Cloud folder handling**
  - OneDrive, Dropbox, Google Drive, iCloud Drive, Box, MEGAsync now treated as low-priority
  - Deferred to end with AppData (likely already backed up to cloud)
  - Clear message when deferring cloud folders
  - Helps maximize recovery of unique local data first

### Rationale
- Cloud-synced folders are usually backed up online
- Local-only data (Pictures, Documents not in cloud) is higher priority
- Still copies cloud folders, just saves them for last

## [1.5.2] - 2025-08-13

### Changed
- **Improved manifest handling**
  - On interrupt: Saves copy to destination but keeps on desktop
  - On completion with errors: Saves to destination but keeps on desktop
  - On successful completion: Moves to destination and removes from desktop
  - Better feedback messages for each scenario

### Rationale
- Preserves work on interrupt while maintaining resume capability
- Desktop manifest is source of truth during recovery
- Only removes from desktop when truly complete

## [1.5.1] - 2025-08-13

### Fixed
- **Critical: $RECYCLE.BIN priority bug**
  - Fixed issue where $RECYCLE.BIN was processed as priority folder if it contained Pictures/Documents
  - Now explicitly excluded from priority categorization
  - Also excludes .Trashes (Mac equivalent)
- **Manifest handling on interrupt**
  - Manifest no longer copied to destination on Ctrl+C
  - Stays on desktop for proper resume capability
  - On resume, checks destination first, then desktop for existing manifests
- **Unique manifest names**
  - Manifests now include source drive name (e.g., recovery_manifest_DriveLabel.txt)
  - Prevents overwriting when recovering multiple drives to same destination
  - Sanitizes drive names for valid filenames
- **Function order bug**
  - Fixed play_completion_sound being called before definition
  - Moved function definition earlier in script

### Changed
- Improved manifest resume logic to handle both interrupted and completed recoveries
- Better feedback when loading existing manifests

### Technical
- Fixed parameter count mismatch in perform_rsync calls
- Integrated deferral system with execute_rsync_with_deferral
- Fixed subshell variable scope issue in deferral logic
- Fixed variable name typo (include_steam_libs → include_steam)

## [1.5.0] - 2025-08-13

### Added
- **Recovery Presets System**
  - 8 preset profiles for different customer types
  - Family/Personal - Prioritizes photos and videos
  - Photographer (Exports) - Edited photos first, then RAW
  - Photographer (RAW) - Original files first
  - Business/Office - Documents, emails, databases
  - Developer - Source code, git repos, configs
  - Gamer/Streamer - Save games, recordings
  - Student/Academic - Homework, research, notes
  - Balanced - General purpose (default)
- **Smart File Deferral**
  - Automatically defers large non-priority files
  - Only defers files >100MB that don't match preset priorities
  - Deferred files processed after all priority data
  - Auto-continues after 10 seconds if no user response
  - Plays sound alert when prompting for deferred files
  - Sorts deferred files: priority types first, then smallest to largest
- **Enhanced Progress Reporting**
  - Shows when files are being deferred
  - Summary of deferred files count and total size
  - Deferred list saved for reference

### Changed
- Interactive mode now asks for recovery preset selection
- Recovery settings now include preset choice
- perform_rsync function accepts preset parameter
- Deferred files maximize file count from failing drives

### Technical Improvements
- Added recovery_presets.sh for preset configurations
- should_defer_file() checks size, location, and preset priorities
- defer_file() tracks files with size and priority scoring
- process_deferred_files() handles deferred list with smart ordering

## [1.4.0] - 2025-08-13

### Fixed
- **Critical: Root-level folder prioritization**
  - Folders now processed in logical priority order instead of filesystem order
  - Priority phases: 1) User data folders, 2) Root files, 3) Backup folders, 4) Normal folders, 5) System folders, 6) Recycle bin
  - $RECYCLE.BIN now processed absolutely last in "Copy Everything" mode
  - Prevents recycle bin from being copied before important user data
- **Critical: Manifest path truncation bug**
  - Fixed regex parsing that truncated folder names with spaces
  - "SRT-PSC Back Up" was incorrectly recorded as "Up" in manifest
  - Now correctly captures full paths including spaces

### Added
- **Smart backup folder detection**
  - Recognizes date-pattern folders (MM-DD-YYYY format)
  - Detects folders with "backup", "computer" in names
  - Special handling for "ip", "iPhone", "iPad" folders
  - Recursively processes backup folders containing Users directories
- **Enhanced root-level processing**
  - Categorizes all root items before processing
  - Maintains single-pass directory reading for failing drives
  - Clear phase indicators during copying
  - Better handling of mixed content external drives

### Changed
- Root folder processing now uses priority arrays instead of random order
- System folders and recycle bin explicitly separated from normal folders
- Improved progress messages showing current processing phase

## [1.3.1] - 2025-08-12

### Changed
- **Optimized Manifest Handling**
  - Manifest now written to user's Desktop during recovery for visibility
  - Additional backup copy maintained on SMB share (if accessible)
  - Updates SMB copy periodically (every 100 files) for safety
  - Eliminates constant writes to destination drive (reduces HDD thrashing)
  - Manifest moved to destination only once at completion
  - Preserves manifest on Desktop if transfer fails or is interrupted
  - Significantly improves performance on external HDDs
  - Users can easily find and manually copy manifest if needed

### Fixed
- Manifest file fragmentation on destination drives
- Unnecessary head movement on external HDDs during manifest updates
- Improved recovery performance by reducing destination drive I/O

## [1.3.0] - 2025-08-12

### Added
- **Fast Resume Mode (Manifest Mode)**
  - New `--fast-resume` flag for dramatically faster resume operations
  - Creates `recovery_manifest.txt` tracking all successfully copied files
  - Skips already-copied files without needing to stat them
  - Especially beneficial for failing drives that struggle with file operations
  - Can be enabled interactively or via command line flag
- **Easy Access Mode**
  - Post-recovery file reorganization for better user experience
  - Automatically detects single vs multi-user scenarios
  - Moves single user's folders to recovery root for direct access
  - Groups system/program folders into "Other files" directory
  - Creates `REORGANIZATION_INFO.txt` documenting all changes
  - Default option during interactive setup
- **Copy Everything Preset**
  - New menu option for full drive/folder sync
  - Copies ALL files including temp files, caches, system files
  - Perfect for backing up external drives
  - Still prioritizes important folders for failing drives
- **Enhanced rsync execution**
  - Unified rsync wrapper function for consistent behavior
  - Itemized output parsing to track completed transfers
  - Automatic manifest building during copy operations

### Changed
- Main menu now includes "Copy Everything" preset option
- Resume operations now offer choice between normal and fast resume
- Interactive setup now asks about file organization preference
- Help text updated to include fast resume option
- Recovery settings now save manifest mode and structure preferences
- Ctrl+C interrupt message now mentions both resume options

### Fixed
- Resume mode now properly passes FILE_STRUCTURE parameter
- Recovery settings location clarified in documentation

### Technical Improvements
- Added `execute_rsync_with_manifest()` function for centralized rsync handling
- Added `build_manifest_excludes()` to convert manifest to rsync exclude patterns
- Added `reorganize_for_easy_access()` function for post-recovery reorganization
- Manifest uses absolute paths for accurate tracking
- Error handling preserved while adding manifest logging

## [1.2.0] - 2025-08-11

### Added
- **File-Type Filtering**: New option to recover only specific file types
  - Pictures (jpg, png, raw formats, HEIC, PSD, etc.)
  - Videos (mp4, avi, mkv, professional formats)
  - Documents (Office files, PDFs, ebooks, text files)
  - Music (mp3, flac, wav, m4a, lossless formats)
- **Enhanced Symlink Handling**
  - Creates `symlinks_map.txt` showing all skipped symlinks and their targets
  - Better detection using `readlink`
  - Summary now shows for all recovery modes, not just full drive
- **Improved Size Estimation**
  - Quick estimate based on partition usage (no directory traversal)
  - Accurate estimate with single-pass directory reading
  - Option to run accurate estimate after quick estimate
- **Better Destination Validation**
  - Won't accept empty destination paths
  - Validates parent directory exists
  - Offers to create destination if it doesn't exist

### Changed
- When using file-type filtering, automatically skips temp files and unnecessary questions
- Symlink skipping now works in all folder scanning, not just Users folder level
- Size estimation now offered as a choice (quick/accurate/skip)

### Fixed
- Fixed issue where "Application Data" symlink was processed as a folder
- Fixed empty destination path causing invalid recovery attempts
- Improved error handling for cross-filesystem operations

## [1.1.0] - 2025-08-06

### Added
- **Resume Capability**: Interrupt with Ctrl+C and resume with `--resume`
- **Recovery Settings**: Saves settings in `~/.rsync_recovery/` for easy resume
- **Recent Recoveries Menu**: Shows last 10 recoveries with timestamps
- **Smart Full Drive Mode**
  - Detects full drives vs user folders automatically
  - Extracts Windows Fonts and Media from system folders
  - Handles Steam libraries with special priority
- **Priority Copying**
  - Pictures/Documents/Desktop first
  - AppData/Library folders last
  - System folders properly identified and skipped

### Changed
- Improved exclude patterns for temp files and caches
- Better handling of Program Files and ProgramData (optional)
- Enhanced progress reporting with colored output

## [1.0.0] - 2025-08-06

### Initial Release
- Basic rsync wrapper with resume support
- Exclude patterns for common temporary files
- Interactive mode with source/destination selection
- Error logging and summary reporting
- Support for Windows and Mac folder structures
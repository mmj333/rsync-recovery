#!/bin/bash

# Progress Monitor for Rsync Recovery
# Monitors destination disk usage to show transfer progress

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Get PID from argument
PARENT_PID="${1:-}"
if [ -z "$PARENT_PID" ]; then
    echo "Usage: $0 <parent_pid>"
    exit 1
fi

# Progress data file
PROGRESS_FILE="/tmp/rsync_progress_${PARENT_PID}.info"
STATE_FILE="/tmp/rsync_progress_${PARENT_PID}.state"

# Wait for progress file to be created
echo "Waiting for recovery to start..."
while [ ! -f "$PROGRESS_FILE" ]; do
    sleep 1
    # Check if parent process still exists
    if ! kill -0 "$PARENT_PID" 2>/dev/null; then
        echo "Parent process ended"
        exit 0
    fi
done

# Read initial values
source "$PROGRESS_FILE"

# Try to find and read manifest for better progress tracking
# First check if manifest was provided in the info file
if [ -z "$MANIFEST_FILE" ] && [ -n "$DEST_PATH" ]; then
    # Look for manifest in destination or desktop
    for manifest in "$DEST_PATH"/rsync_recovery_manifest_*.txt /home/*/Desktop/rsync_recovery_manifest_*.txt; do
        if [ -f "$manifest" ] && grep -q "^# RSYNC_RECOVERY_MANIFEST_V2" "$manifest" 2>/dev/null; then
            MANIFEST_FILE="$manifest"
            break
        fi
    done
fi

# Variables for enhanced tracking
MANIFEST_TOTAL_SIZE=0
MANIFEST_TRANSFERRED_SIZE=0
if [ -n "$MANIFEST_FILE" ]; then
    # Read sizes from manifest header
    MANIFEST_TOTAL_SIZE=$(grep "^# TOTAL_SIZE:" "$MANIFEST_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' ' || echo "0")
    MANIFEST_TRANSFERRED_SIZE=$(grep "^# TRANSFERRED_SIZE:" "$MANIFEST_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' ' || echo "0")
fi

# Validate required variables
if [ -z "$SOURCE_SIZE" ] || [ -z "$DEST_PATH" ] || [ -z "$INITIAL_USED" ] || [ -z "$START_TIME" ]; then
    echo "Error: Missing required progress data"
    exit 1
fi

# Function to format bytes
format_bytes() {
    local bytes="$1"
    if command -v numfmt &> /dev/null; then
        numfmt --to=iec-i --suffix=B --format="%.1f" "$bytes" 2>/dev/null || echo "0B"
    else
        # Manual calculation
        local gb=$((bytes / 1073741824))
        if [ $gb -gt 0 ]; then
            echo "${gb}GB"
        else
            local mb=$((bytes / 1048576))
            echo "${mb}MB"
        fi
    fi
}

# Function to format time
format_time() {
    local seconds="$1"
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    printf "%02d:%02d:%02d" "$hours" "$minutes" "$secs"
}

# Main monitoring loop
echo -e "${GREEN}Recovery Progress Monitor Started${NC}"
echo "Press Ctrl+C to close this window (recovery will continue)"
echo ""

while true; do
    # Check if parent process still exists
    if ! kill -0 "$PARENT_PID" 2>/dev/null; then
        echo -e "\n${GREEN}Recovery process completed!${NC}"
        sleep 3
        exit 0
    fi
    
    # Check state file for current status
    CURRENT_STATE="RUNNING"
    STATE_TRANSFERRED=0
    STATE_TOTAL=0
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE" 2>/dev/null || true
        CURRENT_STATE="${STATE:-RUNNING}"
        STATE_TRANSFERRED="${TRANSFERRED:-0}"
        STATE_TOTAL="${TOTAL:-0}"
    fi
    
    # Update manifest sizes if available
    if [ -n "$MANIFEST_FILE" ] && [ -f "$MANIFEST_FILE" ]; then
        # Re-read sizes from manifest as they update
        MANIFEST_TOTAL_SIZE=$(grep "^# TOTAL_SIZE:" "$MANIFEST_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' ' || echo "0")
        MANIFEST_TRANSFERRED_SIZE=$(grep "^# TRANSFERRED_SIZE:" "$MANIFEST_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' ' || echo "0")
    fi
    
    # Always check current disk usage first
    current_used=$(df -B1 "$DEST_PATH" 2>/dev/null | tail -1 | awk '{print $3}')
    
    if [ -z "$current_used" ]; then
        echo "Warning: Cannot read destination disk usage"
        sleep 10
        continue
    fi
    
    # Calculate progress based on best available data
    if [ "$CURRENT_STATE" = "COMPLETED" ]; then
        # For truly completed transfers, use final state data
        bytes_transferred=$STATE_TRANSFERRED
        total_size=$STATE_TOTAL
        if [ $total_size -eq 0 ] && [ $MANIFEST_TOTAL_SIZE -gt 0 ]; then
            total_size=$MANIFEST_TOTAL_SIZE
            bytes_transferred=$MANIFEST_TRANSFERRED_SIZE
        fi
    else
        # For running or waiting states, always check actual disk usage
        # Start with manifest's previously transferred size
        bytes_transferred=$MANIFEST_TRANSFERRED_SIZE
        
        # Add current session's progress
        current_session_transferred=$((current_used - INITIAL_USED))
        if [ $current_session_transferred -gt 0 ]; then
            bytes_transferred=$((bytes_transferred + current_session_transferred))
        fi
        
        # Use manifest total size if available, otherwise source size
        total_size=$MANIFEST_TOTAL_SIZE
        if [ $total_size -eq 0 ]; then
            total_size=$SOURCE_SIZE
        fi
        
        # If we have state file data and it shows more transferred, use that
        if [ "$CURRENT_STATE" = "WAITING_FOR_USER" ] && [ $STATE_TRANSFERRED -gt $bytes_transferred ]; then
            bytes_transferred=$STATE_TRANSFERRED
            if [ $STATE_TOTAL -gt 0 ]; then
                total_size=$STATE_TOTAL
            fi
        fi
    fi
    
    # Calculate percentage
    if [ $total_size -gt 0 ]; then
        percent=$((bytes_transferred * 100 / total_size))
        # Cap at 100%
        [ $percent -gt 100 ] && percent=100
    else
        percent=0
    fi
    
    # Calculate elapsed time
    current_time=$(date +%s)
    elapsed=$((current_time - START_TIME))
    
    # Calculate rate (bytes per second) with protection against divide by zero
    if [ "$CURRENT_STATE" = "COMPLETED" ]; then
        rate=0
        eta_formatted="--:--:--"
    elif [ "$CURRENT_STATE" = "WAITING_FOR_USER" ]; then
        # Show zero rate but keep checking for size changes
        rate=0
        eta_formatted="--:--:--"
    else
        if [ $elapsed -gt 0 ]; then
            # Only count current session transferred bytes for rate
            current_session_bytes=$((current_used - INITIAL_USED))
            if [ $current_session_bytes -gt 0 ]; then
                rate=$((current_session_bytes / elapsed))
            else
                rate=0
            fi
        else
            rate=0
        fi
        
        # Calculate ETA
        if [ $rate -gt 0 ] && [ $percent -lt 100 ]; then
            remaining=$((total_size - bytes_transferred))
            eta_seconds=$((remaining / rate))
            eta_formatted=$(format_time "$eta_seconds")
        else
            eta_formatted="--:--:--"
        fi
    fi
    
    # Create progress bar
    bar_width=30
    filled=$((percent * bar_width / 100))
    empty=$((bar_width - filled))
    progress_bar="["
    for ((i=0; i<filled; i++)); do progress_bar+="█"; done
    for ((i=0; i<empty; i++)); do progress_bar+="░"; done
    progress_bar+="]"
    
    # Clear screen and display
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          Rsync Recovery Progress Monitor              ║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════╣${NC}"
    
    # Show status
    case "$CURRENT_STATE" in
        "COMPLETED")
            echo -e "${CYAN}║${NC} Status: ${GREEN}✓ TRANSFER COMPLETED${NC}"
            ;;
        "WAITING_FOR_USER")
            echo -e "${CYAN}║${NC} Status: ${YELLOW}⏸ Waiting for user input...${NC}"
            ;;
        *)
            echo -e "${CYAN}║${NC} Status: ${GREEN}▶ Transferring files...${NC}"
            ;;
    esac
    
    echo -e "${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} Progress: ${GREEN}$progress_bar${NC} ${YELLOW}${percent}%${NC}"
    echo -e "${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} Transferred: $(format_bytes "$bytes_transferred") / $(format_bytes "$total_size")"
    echo -e "${CYAN}║${NC} Speed: $(format_bytes "$rate")/s"
    echo -e "${CYAN}║${NC} Elapsed: $(format_time "$elapsed")"
    echo -e "${CYAN}║${NC} Remaining: ${BLUE}$eta_formatted${NC}"
    echo -e "${CYAN}║${NC}"
    
    # Get destination free space
    dest_free=$(df -B1 "$DEST_PATH" 2>/dev/null | tail -1 | awk '{print $4}')
    if [ -n "$dest_free" ]; then
        echo -e "${CYAN}║${NC} Destination free: $(format_bytes "$dest_free")"
    fi
    
    # Show customer/ticket info if available
    if [ -n "$CUSTOMER_NAME" ] || [ -n "$TICKET_NUMBER" ]; then
        echo -e "${CYAN}║${NC}"
        [ -n "$CUSTOMER_NAME" ] && echo -e "${CYAN}║${NC} Customer: $CUSTOMER_NAME"
        [ -n "$TICKET_NUMBER" ] && echo -e "${CYAN}║${NC} Ticket: #$TICKET_NUMBER"
    fi
    
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
    
    # Add warning if very slow
    if [ $rate -gt 0 ] && [ $rate -lt 10485760 ]; then  # Less than 10MB/s
        echo -e "\n${YELLOW}⚠ Transfer speed is slow ($(format_bytes "$rate")/s)${NC}"
    fi
    
    # Update every 10 seconds
    sleep 10
done
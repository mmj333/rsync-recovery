#!/bin/bash

# Test script for progress monitoring

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${GREEN}Progress Monitor Test${NC}"
echo "===================="
echo ""

# Create test directories
TEST_DIR="/tmp/rsync_progress_test_$$"
SOURCE_DIR="$TEST_DIR/source"
DEST_DIR="$TEST_DIR/dest"

echo "Creating test environment..."
mkdir -p "$SOURCE_DIR"/{Documents,Pictures,Videos}
mkdir -p "$DEST_DIR"

# Create some test files
echo "Creating test files..."
for i in {1..10}; do
    dd if=/dev/zero of="$SOURCE_DIR/Documents/doc$i.txt" bs=1M count=5 2>/dev/null
    dd if=/dev/zero of="$SOURCE_DIR/Pictures/pic$i.jpg" bs=1M count=10 2>/dev/null
    dd if=/dev/zero of="$SOURCE_DIR/Videos/vid$i.mp4" bs=1M count=20 2>/dev/null
done

# Calculate total size
TOTAL_SIZE=$(du -sb "$SOURCE_DIR" | awk '{print $1}')
echo -e "${BLUE}Total test data: $(numfmt --to=iec-i --suffix=B "$TOTAL_SIZE")${NC}"

# Test 1: Test progress monitor directly
echo ""
echo -e "${YELLOW}Test 1: Direct progress monitor test${NC}"
echo "--------------------------------------"

# Create progress data file
PROGRESS_FILE="/tmp/rsync_progress_$$.info"
INITIAL_USED=$(df -B1 "$DEST_DIR" 2>/dev/null | tail -1 | awk '{print $3}')

cat > "$PROGRESS_FILE" << EOF
SOURCE_SIZE=$TOTAL_SIZE
DEST_PATH=$DEST_DIR
INITIAL_USED=$INITIAL_USED
START_TIME=$(date +%s)
CUSTOMER_NAME=TestCustomer
TICKET_NUMBER=12345
EOF

echo "Launching progress monitor..."
echo "Starting rsync in 3 seconds..."

# Launch monitor
"$SCRIPT_DIR/progress_monitor.sh" "$$" &
MONITOR_PID=$!

sleep 3

# Run rsync
echo ""
echo "Starting rsync transfer..."
rsync -avh --progress "$SOURCE_DIR/" "$DEST_DIR/"
RSYNC_EXIT=$?

# Wait a bit for final update
sleep 12

# Clean up monitor
kill $MONITOR_PID 2>/dev/null

echo ""
if [ $RSYNC_EXIT -eq 0 ]; then
    echo -e "${GREEN}Transfer completed successfully${NC}"
    
    # Verify data transferred
    DEST_SIZE=$(du -sb "$DEST_DIR" | awk '{print $1}')
    echo "Source size: $(numfmt --to=iec-i --suffix=B "$TOTAL_SIZE")"
    echo "Dest size:   $(numfmt --to=iec-i --suffix=B "$DEST_SIZE")"
else
    echo -e "${RED}Transfer failed with exit code: $RSYNC_EXIT${NC}"
fi

# Test 2: Test with main script
echo ""
echo -e "${YELLOW}Test 2: Test with main recovery script${NC}"
echo "---------------------------------------"
echo "This would test the full integration with rsync_recovery.sh"
echo "Run: USE_PROGRESS_MONITOR=yes $SCRIPT_DIR/rsync_recovery.sh"

# Cleanup
echo ""
echo "Cleaning up test files..."
rm -rf "$TEST_DIR"
rm -f "$PROGRESS_FILE"

echo ""
echo -e "${GREEN}Test complete!${NC}"
echo ""
echo "Notes:"
echo "- Progress monitor updates every 10 seconds"
echo "- Shows progress based on destination disk usage"
echo "- Automatically exits when parent process ends"
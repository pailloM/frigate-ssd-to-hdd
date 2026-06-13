#!/usr/bin/env bats

# ============================================================================
# BATS Test Suite for SSD-to-HDD Migration Script
# ============================================================================

# Setup: Create temporary test environment before each test
setup() {
    # Create temporary directories for testing
    export TEST_DIR="./test_tmp"
    export SSD_BASE="$TEST_DIR/ssd"
    export HDD_BASE="$TEST_DIR/hdd"
    
    mkdir -p "$SSD_BASE/recordings" "$SSD_BASE/clips"
    mkdir -p "$HDD_BASE/recordings" "$HDD_BASE/clips"
    
    # Set environment variables for tests
    export MIN_AGE_DAYS=0
    export LOCKFILE="$TEST_DIR/ssd_to_hdd.lock"
    #source ssd-to-hdd.sh --source-only 2>/dev/null || true
}

# Teardown: Clean up test environment after each test
teardown() {
    # Remove lock file
    # [ -f "$LOCKFILE" ] && rm -f "$LOCKFILE"
    rm -f "$LOCKFILE"
    # Remove entire test directory
    # [ -d "$TEST_DIR" ] && rm -rf "$TEST_DIR"
    rm -rf "$TEST_DIR"
}

# ============================================================================
# HELPER FUNCTIONS FOR TESTS
# ============================================================================

# Create test files with specific age
create_test_file() {
    local path="$1"
    local age_days="${2:-0}"
    
    mkdir -p "$(dirname "$path")"
    touch "$path"
    
    if [ "$age_days" -gt 0 ]; then
        touch -d "$age_days days ago" "$path"
    fi
}

# Count files in directory
count_files() {
    find "$1" -type f 2>/dev/null | wc -l
}

# ============================================================================
# TEST: Basic Sync Operation
# ============================================================================

@test "sync: moves files from SSD to HDD and creates symlinks" {
    create_test_file "$SSD_BASE/recordings/file1.mp4"
    create_test_file "$SSD_BASE/clips/file2.mp4"
    
    ./ssd-to-hdd.sh sync

    [ -f "$HDD_BASE/recordings/file1.mp4" ]
    [ -f "$HDD_BASE/clips/file2.mp4" ]
    [ -L "$SSD_BASE/recordings/file1.mp4" ]
    [ -L "$SSD_BASE/clips/file2.mp4" ]
}

@test "sync: preserves directory structure" {
    create_test_file "$SSD_BASE/recordings/2026/01/15/file.mp4"
    create_test_file "$SSD_BASE/clips/camera1/2026-01-15_10-00.mp4"
    
    ./ssd-to-hdd.sh sync
    
    [ -d "$HDD_BASE/recordings/2026/01/15" ]
    [ -d "$HDD_BASE/clips/camera1" ]
    [ -f "$HDD_BASE/recordings/2026/01/15/file.mp4" ]
    [ -f "$HDD_BASE/clips/camera1/2026-01-15_10-00.mp4" ]
}

@test "sync: skips files already on HDD" {
    create_test_file "$SSD_BASE/recordings/file.mp4"
    create_test_file "$HDD_BASE/recordings/file.mp4"
    
    local original_mtime
    original_mtime=$(stat -c%Y "$HDD_BASE/recordings/file.mp4" 2>/dev/null || stat -f%m "$HDD_BASE/recordings/file.mp4")
    
    sleep 1
    
    ./ssd-to-hdd.sh sync
    
    local new_mtime
    new_mtime=$(stat -c%Y "$HDD_BASE/recordings/file.mp4" 2>/dev/null || stat -f%m "$HDD_BASE/recordings/file.mp4")
    
    [ "$original_mtime" = "$new_mtime" ]
}

@test "sync: handles empty directories gracefully" {
    mkdir -p "$SSD_BASE/recordings/empty"
    
    ./ssd-to-hdd.sh sync
    
    [ $? -eq 0 ]
}

@test "sync: does nothing if subdirectory doesn't exist" {
    rmdir "$SSD_BASE/recordings"
    
    ./ssd-to-hdd.sh sync
    
    [ $? -eq 0 ]
}

@test "sync: symlink points to correct HDD location" {
    create_test_file "$SSD_BASE/recordings/test.mp4"
    
    ./ssd-to-hdd.sh sync
    
    [ -L "$SSD_BASE/recordings/test.mp4" ]
    [ "$(readlink "$SSD_BASE/recordings/test.mp4")" = "$HDD_BASE/recordings/test.mp4" ]
}

# ============================================================================
# TEST: Cleanup HDD Operation
# ============================================================================

@test "./sync_to_hdd.sh cleanup_hdd: deletes files with no SSD reference" {
    create_test_file "$HDD_BASE/recordings/orphaned.mp4"
    
    ./ssd-to-hdd.sh cleanup "recordings"
    
    [ ! -f "$HDD_BASE/recordings/orphaned.mp4" ]
}

@test "./sync_to_hdd.sh cleanup_hdd: preserves files with valid SSD symlinks" {
    create_test_file "$HDD_BASE/recordings/file.mp4"
    mkdir -p "$SSD_BASE/recordings"
    ln -s "$HDD_BASE/recordings/file.mp4" "$SSD_BASE/recordings/file.mp4"
    
    ./ssd-to-hdd.sh cleanup "recordings"
    
    [ -f "$HDD_BASE/recordings/file.mp4" ]
}

@test "./sync_to_hdd.sh cleanup_hdd: removes empty directories" {
    mkdir -p "$HDD_BASE/recordings/2026/01/15/empty"
    create_test_file "$HDD_BASE/recordings/2026/01/15/file.mp4"
    
    ln -s "$HDD_BASE/recordings/2026/01/15/file.mp4" "$SSD_BASE/recordings/file.mp4"
    
    rm "$HDD_BASE/recordings/2026/01/15/file.mp4"
    
    ./ssd-to-hdd.sh cleanup "recordings"
    
    [ ! -d "$HDD_BASE/recordings/2026/01/15/empty" ]
    [ ! -d "$HDD_BASE/recordings/2026/01/15" ]
    [ ! -d "$HDD_BASE/recordings/2026" ]
}

@test "cleanup_hdd: handles missing HDD directory gracefully" {
    rmdir "$HDD_BASE/recordings"
    
    ./ssd-to-hdd.sh cleanup "recordings"
    
    [ $? -eq 0 ]
}

@test "cleanup_hdd: preserves symlinks that still have targets" {
    create_test_file "$HDD_BASE/recordings/file1.mp4"
    create_test_file "$HDD_BASE/recordings/file2.mp4"
    mkdir -p "$SSD_BASE/recordings"
    ln -s "$HDD_BASE/recordings/file1.mp4" "$SSD_BASE/recordings/file1.mp4"
    ln -s "$HDD_BASE/recordings/file2.mp4" "$SSD_BASE/recordings/file2.mp4"
    
    ./ssd-to-hdd.sh cleanup "recordings"
    
    [ -f "$HDD_BASE/recordings/file1.mp4" ]
    [ -f "$HDD_BASE/recordings/file2.mp4" ]
}

# ============================================================================
# TEST: Symlink Repair Operation
# ============================================================================

@test "repair_symlinks: creates missing symlinks" {
    create_test_file "$HDD_BASE/recordings/file.mp4"
    
    ./ssd-to-hdd.sh repair "recordings"
    
    [ -L "$SSD_BASE/recordings/file.mp4" ]
    [ "$(readlink "$SSD_BASE/recordings/file.mp4")" = "$HDD_BASE/recordings/file.mp4" ]
}

@test "repair_symlinks: fixes broken symlinks" {
    mkdir -p "$SSD_BASE/recordings"
    ln -s "$HDD_BASE/recordings/nonexistent.mp4" "$SSD_BASE/recordings/broken.mp4"
    
    create_test_file "$HDD_BASE/recordings/broken.mp4"
    
    ./ssd-to-hdd.sh repair "recordings"
    
    [ -L "$SSD_BASE/recordings/broken.mp4" ]
    [ -e "$HDD_BASE/recordings/broken.mp4" ]
    [ "$(readlink "$SSD_BASE/recordings/broken.mp4")" = "$HDD_BASE/recordings/broken.mp4" ]
}

@test "repair_symlinks: skips valid symlinks" {
    create_test_file "$HDD_BASE/recordings/file.mp4"
    mkdir -p "$SSD_BASE/recordings"
    ln -s "$HDD_BASE/recordings/file.mp4" "$SSD_BASE/recordings/file.mp4"
    
    local original_mtime
    original_mtime=$(stat -L -c%Y "$SSD_BASE/recordings/file.mp4" 2>/dev/null || stat -c%m "$SSD_BASE/recordings/file.mp4")
    sleep 1
    
    ./ssd-to-hdd.sh repair "recordings"
    
    local new_mtime
    new_mtime=$(stat -L -c%Y "$SSD_BASE/recordings/file.mp4" 2>/dev/null || stat -c%m "$SSD_BASE/recordings/file.mp4")
    
    [ "$original_mtime" = "$new_mtime" ]
}

@test "repair_symlinks: preserves directory structure" {
    create_test_file "$HDD_BASE/recordings/2026/01/15/file.mp4"
    
    ./ssd-to-hdd.sh repair "recordings"
    
    [ -d "$SSD_BASE/recordings/2026/01/15" ]
    [ -L "$SSD_BASE/recordings/2026/01/15/file.mp4" ]
}

@test "repair_symlinks: handles missing HDD directory gracefully" {
    rmdir "$HDD_BASE/recordings"
    
    ./ssd-to-hdd.sh repair "recordings"
    
    [ $? -eq 0 ]
}

# ============================================================================
# TEST: Revert Operation
# ============================================================================

@test "revert: moves files back from HDD to SSD and removes symlinks" {
    create_test_file "$HDD_BASE/recordings/file.mp4"
    mkdir -p "$SSD_BASE/recordings"
    ln -s "$HDD_BASE/recordings/file.mp4" "$SSD_BASE/recordings/file.mp4"
    
    ./ssd-to-hdd.sh revert "recordings"
    
    [ -f "$SSD_BASE/recordings/file.mp4" ]
    [ ! -L "$SSD_BASE/recordings/file.mp4" ]
    [ ! -f "$HDD_BASE/recordings/file.mp4" ]
}

@test "revert: removes broken symlinks" {
    mkdir -p "$SSD_BASE/recordings"
    ln -s "$HDD_BASE/recordings/nonexistent.mp4" "$SSD_BASE/recordings/broken.mp4"
    
    ./ssd-to-hdd.sh revert "recordings"
    
    [ ! -L "$SSD_BASE/recordings/broken.mp4" ]
    [ ! -e "$SSD_BASE/recordings/broken.mp4" ]
}

@test "revert: handles missing HDD files gracefully" {
    mkdir -p "$SSD_BASE/recordings"
    ln -s "$HDD_BASE/recordings/missing.mp4" "$SSD_BASE/recordings/missing.mp4"
    
    ./ssd-to-hdd.sh revert "recordings"
    
    [ $? -eq 0 ]
    [ ! -L "$SSD_BASE/recordings/missing.mp4" ]
}

@test "revert: removes empty HDD directories" {
    create_test_file "$HDD_BASE/recordings/2026/01/15/file.mp4"
    mkdir -p "$SSD_BASE/recordings/2026/01/15"
    ln -s "$HDD_BASE/recordings/2026/01/15/file.mp4" "$SSD_BASE/recordings/2026/01/15/file.mp4"
    
    ./ssd-to-hdd.sh revert "recordings"
    
    [ ! -d "$HDD_BASE/recordings/2026" ]
}

@test "revert: handles missing SSD directory gracefully" {
    rmdir "$SSD_BASE/recordings"
    
    ./ssd-to-hdd.sh revert "recordings"
    
    [ $? -eq 0 ]
}

# ============================================================================
# TEST: Integration Scenarios
# ============================================================================

@test "integration: full sync and cleanup cycle" {
    create_test_file "$SSD_BASE/recordings/file1.mp4"
    create_test_file "$SSD_BASE/clips/clip1.mp4"
    
    ./ssd-to-hdd.sh sync
    ./ssd-to-hdd.sh cleanup
    
    [ -f "$HDD_BASE/recordings/file1.mp4" ]
    [ -f "$HDD_BASE/clips/clip1.mp4" ]
    [ -L "$SSD_BASE/recordings/file1.mp4" ]
}
#!/bin/bash


log() {
    local level="${2:-INFO}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $1" >&2
}

log_error() {
    log "$1" "ERROR" >&2
}

LOCKFILE="/var/lock/ssd_to_hdd.lock"
WORK_IN_PROGRESS=""  # Track current operation

cleanup() {

    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log_error "Caught signal. Cleaning up..."
    else
        log "Exiting, cleaning up..."
    fi

    if [ -n "$WORK_IN_PROGRESS" ]; then
        log_error "Migration interrupted. File in progress: $WORK_IN_PROGRESS"
    fi
    
    exec 9>&-
    rm -f -- "$LOCKFILE"

    log "Done!"

    exit "$exit_code"

}
trap cleanup EXIT SIGTERM SIGINT

exec 9>"$LOCKFILE"
if ! flock -n 9; then
    log_error "Another instance is running; exiting."
    exit 1
fi

set -euo pipefail

readonly SSD_BASE="${SSD_BASE:-/media/frigate}"
readonly HDD_BASE="${HDD_BASE:-/media/frigate-hdd}"
readonly SUBDIRS=("recordings" "clips")
readonly MIN_AGE_DAYS="${MIN_AGE_DAYS:-0}"

if [ ! -d "$SSD_BASE" ] || [ ! -d "$HDD_BASE" ]; then
    log_error "SSD_BASE or HDD_BASE directory does not exist"
    exit 1
fi

ensure_dir() {
    [ -d "$1" ] || mkdir -p -- "$1"
}

sync_to_hdd() {
    local subdir="$1"
    local ssd_dir="$SSD_BASE/$subdir"
    local hdd_dir="$HDD_BASE/$subdir"
    
    [ -d "$ssd_dir" ] || return 0
    ensure_dir "$hdd_dir"

    local log_msg="Starting SSD → HDD sync for $subdir"
    [ "$MIN_AGE_DAYS" -gt 0 ] && log_msg+=" (files older than ${MIN_AGE_DAYS} days)"
    log "$log_msg"

    local file_count=0

    while IFS= read -r -d '' ssd_file;  do
        local rel_path="${ssd_file#"$ssd_dir/"}"
        local hdd_file="$hdd_dir/$rel_path"
        WORK_IN_PROGRESS="$ssd_file"

        # Skip if file already migrated
        [ -f "$hdd_file" ] && continue

        # CHANGE: Use single mkdir instead of separate call
        mkdir -p -- "$(dirname "$hdd_file")"
        
        # Use atomic move with error handling
        if mv -- "$ssd_file" "$hdd_file"; then
            ln -s -- "$hdd_file" "$ssd_file" || {
                log_error "Failed to create symlink for $rel_path"
                mv -- "$hdd_file" "$ssd_file"  # Rollback
                continue
            }
            ((file_count++))
            log "Moved $ssd_file to $hdd_file"
        else
            log_error "Failed to move $rel_path"
        fi
        WORK_IN_PROGRESS=""
    done < <(
        find "$ssd_dir" -type f \
            -mtime "${MIN_AGE_DAYS}" \
            -print0
    )

    log "SSD → HDD sync complete for $subdir ($file_count files moved)"
}

cleanup_hdd() {
    local subdir="$1"
    local ssd_dir="$SSD_BASE/$subdir"
    local hdd_dir="$HDD_BASE/$subdir"
    
    [ -d "$hdd_dir" ] || return 0

    log "Starting HDD cleanup for $subdir"
    local file_count=0

    while IFS= read -r -d '' hdd_file; do
        local rel_path="${hdd_file#"$hdd_dir/"}"
        local ssd_path="$ssd_dir/$rel_path"
        WORK_IN_PROGRESS="$hdd_file"

        # If Frigate removed the entry from SSD entirely, delete from HDD
        if [ ! -e "$ssd_path" ] && [ ! -L "$ssd_path" ]; then
            rm -f -- "$hdd_file" && ((file_count++))
        fi
        WORK_IN_PROGRESS=""
    done < <(find "$hdd_dir" -type f -print0)

    find "$hdd_dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true

    log "HDD cleanup complete for $subdir ($file_count files deleted)"
}

repair_symlinks() {
    local subdir="$1"
    local ssd_dir="$SSD_BASE/$subdir"
    local hdd_dir="$HDD_BASE/$subdir"
    
    [ -d "$hdd_dir" ] || return 0

    log "Starting symlink repair for $subdir"
    local repair_count=0

    while IFS= read -r -d '' hdd_file; do
        local rel_path="${hdd_file#"$hdd_dir/"}"
        local ssd_path="$ssd_dir/$rel_path"

        # Skip if a valid symlink already exists
        if [ -L "$ssd_path" ] && [ -e "$ssd_path" ]; then
            continue
        fi


        [ -L "$ssd_path" ] && rm -f -- "$ssd_path"

        ensure_dir "$(dirname "$ssd_path")"
        
        if ln -s -- "$hdd_file" "$ssd_path"; then
            ((repair_count++))
        else
            log_error "Failed to repair symlink for $rel_path"
        fi
    done < <(find "$hdd_dir" -type f -print0)

    log "Symlink repair complete for $subdir ($repair_count symlinks repaired)"
}

revert() {
    local subdir="$1"
    local ssd_dir="$SSD_BASE/$subdir"
    local hdd_dir="$HDD_BASE/$subdir"
    
    [ -d "$ssd_dir" ] || return 0

    log "Starting revert for $subdir"
    local reverted_count=0
    local removed_count=0

    while IFS= read -r -d '' ssd_link; do
        local rel_path="${ssd_link#"$ssd_dir/"}"
        local hdd_file="$hdd_dir/$rel_path"

        if [ -f "$hdd_file" ]; then
            rm -f -- "$ssd_link" && \
            if mv -- "$hdd_file" "$ssd_link"
            then
                ((reverted_count++))
            else
                log_error "Failed to revert $rel_path"
            fi
        else
            rm -f -- "$ssd_link" && ((removed_count++))
        fi
    done < <(find "$ssd_dir" -type l -print0)

    find "$hdd_dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true

    log "Revert complete for $subdir ($reverted_count reverted, $removed_count broken symlinks removed)"
}

main() {
    case "${1:-}" in
        sync)
            # NEW: Loop with status tracking
            for subdir in "${SUBDIRS[@]}"; do
                sync_to_hdd "$subdir" || log_error "sync_to_hdd failed for $subdir"
                cleanup_hdd "$subdir" || log_error "cleanup_hdd failed for $subdir"
            done
            ;;
        repair)
            for subdir in "${SUBDIRS[@]}"; do
                repair_symlinks "$subdir" || log_error "repair_symlinks failed for $subdir"
            done
            ;;
        revert)
            for subdir in "${SUBDIRS[@]}"; do
                revert "$subdir" || log_error "revert failed for $subdir"
            done
            ;;
        cleanup)
            for subdir in "${SUBDIRS[@]}"; do
                cleanup_hdd "$subdir" || log_error "cleanup_hdd failed for $subdir"
            done
            ;;
        *)
            cat >&2 << 'EOF'
Usage: $0 {sync|repair|revert|cleanup}

Commands:
  sync      - Migrate files from SSD to HDD, create symlinks on SSD
  repair    - Repair broken symlinks on SSD pointing to HDD
  revert    - Move files back from HDD to SSD, remove symlinks
  cleanup   - Remove HDD files where symlinks have been removed on the SSD

Environment Variables:
  MIN_AGE_DAYS    - Only sync files older than N days (default: 0)
  SSD_BASE        - SSD mount point (default: /media/frigate)
  HDD_BASE        - HDD mount point (default: /media/frigate-hdd)
EOF
            exit 1
            ;;
    esac
}

main "$@"
